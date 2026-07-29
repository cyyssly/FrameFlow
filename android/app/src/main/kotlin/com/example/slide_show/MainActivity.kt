package com.example.slide_show

import android.Manifest
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.slide_show/media_store"
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getImageAlbums" -> handleGetImageAlbums(result)
                "requestStoragePermission" -> handleRequestPermission(result)
                "readImageBytes" -> {
                    val path = call.argument<String>("path") ?: ""
                    handleReadImageBytes(path, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingResult?.success(granted)
            pendingResult = null
        }
    }

    private fun handleGetImageAlbums(result: MethodChannel.Result) {
        if (!hasStoragePermission()) {
            result.error("PERMISSION_DENIED", "没有读取图片的权限", null)
            return
        }
        try {
            val albums = queryImageAlbums()
            result.success(albums)
        } catch (e: Exception) {
            result.error("QUERY_FAILED", "查询相册失败: ${e.message}", null)
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }
        pendingResult = result
        val permission = getRequiredPermission()
        ActivityCompat.requestPermissions(this, arrayOf(permission), 100)
    }

    private fun handleReadImageBytes(path: String, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("FILE_NOT_FOUND", "文件不存在: $path", null)
                return
            }
            result.success(file.readBytes())
        } catch (e: Exception) {
            result.error("READ_FAILED", "读取文件失败: ${e.message}", null)
        }
    }

    private fun hasStoragePermission(): Boolean {
        val permission = getRequiredPermission()
        return ContextCompat.checkSelfPermission(this, permission) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun getRequiredPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun queryImageAlbums(): List<Map<String, Any>> {
        val albums = mutableListOf<Map<String, Any>>()
        val contentResolver: ContentResolver = contentResolver

        val projection = arrayOf(
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.DATA
        )

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }

        val cursor = contentResolver.query(
            collection,
            projection,
            null,
            null,
            "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} ASC"
        )

        cursor?.use {
            val albumMap = mutableMapOf<Long, AlbumData>()

            while (it.moveToNext()) {
                val bucketId = it.getLong(it.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID))
                val bucketName = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME))
                val dataPath = it.getString(it.getColumnIndexOrThrow(MediaStore.Images.Media.DATA))

                val album = albumMap.getOrPut(bucketId) {
                    AlbumData(
                        name = bucketName,
                        representativePath = dataPath,
                        count = 0
                    )
                }
                album.count++
            }

            for ((_, albumData) in albumMap) {
                val albumPath = getAlbumDirectoryPath(albumData.representativePath)
                if (albumPath != null) {
                    albums.add(
                        mapOf(
                            "name" to albumData.name,
                            "path" to albumPath,
                            "imageCount" to albumData.count
                        )
                    )
                }
            }
        }

        albums.sortByDescending { it["imageCount"] as Int }
        return albums.filter { (it["imageCount"] as Int) > 0 }
    }

    private fun getAlbumDirectoryPath(imagePath: String?): String? {
        if (imagePath == null) return null
        val lastSlash = imagePath.lastIndexOf('/')
        return if (lastSlash > 0) imagePath.substring(0, lastSlash) else null
    }

    data class AlbumData(
        val name: String,
        val representativePath: String,
        var count: Int
    )
}