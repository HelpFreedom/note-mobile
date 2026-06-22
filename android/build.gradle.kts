allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Некоторые плагины (file_picker и др.) пиннят старый compileSdk (34), а их
// транзитивные зависимости требуют 36. Поднимаем compileSdk до 36 для всех
// под-проектов-плагинов через рефлексию (без импорта типов AGP в корневой скрипт).
// ВАЖНО: до блока evaluationDependsOn(":app"), иначе afterEvaluate регистрируется
// на уже вычисленном проекте.
subprojects {
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        try {
            val method = android.javaClass.methods.firstOrNull {
                it.name == "compileSdkVersion" &&
                    it.parameterTypes.size == 1 &&
                    it.parameterTypes[0] == Int::class.javaPrimitiveType
            }
            method?.invoke(android, 36)
        } catch (_: Exception) {
            // не критично — оставляем как есть
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
