package dev.qtnotes.qtnotes_mobile

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import android.view.WindowManager
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Аппаратный гейт ПИНа через Android Keystore (зеркало TPM на десктопе) + быстрый
 * нативный AES + ОПЦИОНАЛЬНАЯ аппаратная аутентификация устройства (биометрия/код).
 *
 * Если HMAC-ключ создан с requireAuth=true (setUserAuthenticationRequired), его нельзя
 * использовать без свежей аутентификации устройства — это enforce'ит ЖЕЛЕЗО, а не наш
 * код. Биометрия запрашивается «по требованию» прямо в hmac(), когда ключ заблокирован.
 *
 * FlutterFragmentActivity нужен для androidx BiometricPrompt.
 */
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "qtnotes/keystore"
    private val keystore = "AndroidKeyStore"
    private val cryptoExec = Executors.newSingleThreadExecutor()
    // M6: окно валидности после аутентификации (сек). Одна разблокировка делает НЕСКОЛЬКО
    // hmac-операций (wrap-ключ + duress-тег), поэтому окно > 0 нужно, чтобы один запрос
    // биометрии покрывал их все (per-use CryptoObject прыгал бы биометрией на каждую). Окно
    // ужато с 20с до 5с: его хватает на серию hmac+scrypt сразу после auth, но «попутное»
    // использование MK посторонним кодом резко ограничено по времени.
    private val authValiditySeconds = 5

    // D3 (раунд-3): FLAG_SECURE — плейнтекст заметок и PIN-экран не попадают в превью
    // переключателя задач и не скриншотятся/не записываются с экрана.
    override fun onCreate(savedInstanceState: Bundle?) {
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "aesGcmEncrypt", "aesGcmDecrypt" -> {
                        val encrypt = call.method == "aesGcmEncrypt"
                        val key = call.argument<ByteArray>("key")!!
                        val nonce = call.argument<ByteArray>("nonce")!!
                        val aad = call.argument<ByteArray>("aad") ?: ByteArray(0)
                        val data = call.argument<ByteArray>("data")!!
                        cryptoExec.execute {
                            try {
                                val out = aesGcm(encrypt, key, nonce, aad, data)
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("AES_ERROR", e.message, null) }
                            }
                        }
                    }
                    // HMAC: при requireAuth и заблокированном ключе показываем биометрию
                    // и повторяем — поэтому результат может прийти асинхронно.
                    "hmac" -> hmacMaybeAuth(
                        call.argument<String>("alias")!!,
                        call.argument<ByteArray>("data")!!, result)
                    // Явная аутентификация устройства (для КОНСИСТЕНТНОГО запроса биометрии
                    // при каждой разблокировке; успех обновляет окно валидности ключа).
                    "authenticateDevice" -> runOnUiThread {
                        showAuth(
                            onSuccess = { result.success(true) },
                            onError = { result.success(false) },
                        )
                    }
                    else -> try {
                        when (call.method) {
                            "ensureHmacKey" -> {
                                ensureHmacKey(call.argument<String>("alias")!!,
                                    call.argument<Boolean>("requireAuth") ?: false)
                                result.success(true)
                            }
                            "hasKey" -> result.success(hasKey(call.argument<String>("alias")!!))
                            "deleteKey" -> {
                                deleteKey(call.argument<String>("alias")!!)
                                result.success(true)
                            }
                            "canDeviceAuth" -> result.success(canDeviceAuth())
                            "copySensitive" -> {
                                copySensitive(call.argument<String>("text") ?: "")
                                result.success(true)
                            }
                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("KEYSTORE_ERROR", e.message, null)
                    }
                }
            }
    }

    private fun aesGcm(encrypt: Boolean, key: ByteArray, nonce: ByteArray, aad: ByteArray,
                       data: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, nonce),
        )
        if (aad.isNotEmpty()) cipher.updateAAD(aad)
        return cipher.doFinal(data)
    }

    private fun ks(): KeyStore = KeyStore.getInstance(keystore).apply { load(null) }
    private fun hasKey(alias: String): Boolean = ks().containsAlias(alias)

    private fun ensureHmacKey(alias: String, requireAuth: Boolean) {
        if (ks().containsAlias(alias)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                generateKey(alias, strongBox = true, requireAuth = requireAuth)
                return
            } catch (_: StrongBoxUnavailableException) {
            }
        }
        generateKey(alias, strongBox = false, requireAuth = requireAuth)
    }

    private fun generateKey(alias: String, strongBox: Boolean, requireAuth: Boolean) {
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, keystore)
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setDigests(KeyProperties.DIGEST_SHA256)
        if (requireAuth) {
            // ключ нельзя использовать без свежей аутентификации устройства (железо).
            // Validity-duration режим: принимает биометрию ИЛИ код блокировки устройства,
            // действителен authValiditySeconds после аутентификации. Работает на всех API.
            spec.setUserAuthenticationRequired(true)
            @Suppress("DEPRECATION")
            spec.setUserAuthenticationValidityDurationSeconds(authValiditySeconds)
            // D1 (раунд-3): дозапись нового отпечатка/лица ИНВАЛИДИРУЕТ ключ — атакующий с
            // разблокированным телефоном не сможет добавить свою биометрию и пройти гейт.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                spec.setInvalidatedByBiometricEnrollment(true)
            }
            // D1: ключ непригоден, пока устройство ЗАблокировано (сужает окно «попутного»
            // использования MK фоновым кодом при заблокированном экране).
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                spec.setUnlockedDeviceRequired(true)
            }
        }
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            spec.setIsStrongBoxBacked(true)
        }
        kg.init(spec.build())
        kg.generateKey()
    }

    private fun computeHmac(alias: String, data: ByteArray): ByteArray {
        val key = ks().getKey(alias, null) as SecretKey
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(key)
        return mac.doFinal(data)
    }

    private fun hmacMaybeAuth(alias: String, data: ByteArray, result: MethodChannel.Result) {
        try {
            result.success(computeHmac(alias, data))
        } catch (e: UserNotAuthenticatedException) {
            // ключ требует аутентификации устройства — показать биометрию и повторить
            runOnUiThread {
                showAuth(
                    onSuccess = {
                        try {
                            result.success(computeHmac(alias, data))
                        } catch (e2: Exception) {
                            result.error("HMAC_ERROR", e2.message, null)
                        }
                    },
                    onError = { msg -> result.error("AUTH_CANCELLED", msg, null) },
                )
            }
        } catch (e: Exception) {
            result.error("HMAC_ERROR", e.message, null)
        }
    }

    private fun authenticators(): Int =
        BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL

    private fun canDeviceAuth(): Boolean =
        BiometricManager.from(this).canAuthenticate(authenticators()) ==
            BiometricManager.BIOMETRIC_SUCCESS

    private fun showAuth(onSuccess: () -> Unit, onError: (String) -> Unit) {
        val executor = ContextCompat.getMainExecutor(this)
        val prompt = BiometricPrompt(this, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                    onSuccess()
                }
                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    onError(msg.toString())
                }
            })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Разблокировка QtNotes")
            .setSubtitle("Подтвердите вход на устройстве")
            .setAllowedAuthenticators(authenticators())
            .build()
        prompt.authenticate(info)
    }

    private fun deleteKey(alias: String) {
        val ks = ks()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
    }

    // D4 (раунд-3): копировать заметку в буфер, помечая содержимое чувствительным —
    // на Android 13+ система не показывает превью и не тащит в облачную историю буфера.
    private fun copySensitive(text: String) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("note", text)
        if (Build.VERSION.SDK_INT >= 33) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        cm.setPrimaryClip(clip)
    }
}
