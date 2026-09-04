allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            name = "linphone.org maven repository"
            url = uri("https://download.linphone.org/maven_repository")
            content {
                includeGroup("org.linphone")
                includeGroup("org.linphone.no-video")
            }
        }
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
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
