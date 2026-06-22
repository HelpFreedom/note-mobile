// Runtime-состояние разблокировки (зеркало qtnotes/crypto/session.py).
//
// Пока приложение разблокировано, мастер-ключ лежит здесь и используется крипто-слоем
// хранилища. encryptionEnabled — включено ли шифрование (загружается из настроек при
// старте). На диск отсюда ничего не пишется.

class Session {
  static List<int>? masterKey;
  static bool encryptionEnabled = false;

  static bool get isUnlocked => masterKey != null;

  static void lock() => masterKey = null;
}
