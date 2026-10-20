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
// 个别插件在其 android/build.gradle 中声明了偏低的 compileSdk（file_picker 9.0.3 声明 34），
// 低于其依赖（flutter_plugin_android_lifecycle）要求的 36，会触发 AGP 的
// checkReleaseAarMetadata 校验失败。插件源码位于 pub 缓存中不便修改，
// 因此在这里统一把所有 Android 子项目的 compileSdk 提升到与应用一致的值。
// 必须在下面的 evaluationDependsOn(":app") 之前注册 afterEvaluate：
// 该语句会立即评估 :app，之后再注册会抛出 "project is already evaluated"。
val androidCompileSdk = 36

subprojects {
    afterEvaluate {
        val androidExtension = project.extensions.findByName("android") ?: return@afterEvaluate
        val compileSdkSetter =
            androidExtension.javaClass.methods.firstOrNull { method ->
                method.name in listOf(
                    "setCompileSdkVersion",
                    "setCompileSdk",
                    "compileSdkVersion",
                    "compileSdk",
                ) &&
                    method.parameterTypes.size == 1 &&
                    method.parameterTypes[0].name in listOf("int", "java.lang.Integer")
            }
        compileSdkSetter?.invoke(androidExtension, androidCompileSdk)
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
