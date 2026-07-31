package com.example.slide_show

import android.Manifest
import android.content.ContentResolver
import android.content.pm.PackageManager
import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.os.Environment
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
            // 只要有一个权限被授予，就认为可以读取（部分照片也能用）
            val granted = grantResults.isNotEmpty() &&
                grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            pendingResult?.success(granted)
            pendingResult = null
        }
    }

    private fun handleGetImageAlbums(result: MethodChannel.Result) {
        if (!hasStoragePermission()) {
            android.util.Log.e("FrameFlow", "getImageAlbums: permission denied")
            result.error("PERMISSION_DENIED", "没有读取图片的权限", null)
            return
        }
        try {
            val albums = queryImageAlbums()
            android.util.Log.d("FrameFlow", "getImageAlbums: returning ${albums.size} albums")
            for (album in albums) {
                android.util.Log.d("FrameFlow", "  album: ${album["name"]} path=${album["path"]} count=${album["imageCount"]}")
            }
            result.success(albums)
        } catch (e: Exception) {
            android.util.Log.e("FrameFlow", "getImageAlbums: query failed: ${e.message}", e)
            result.error("QUERY_FAILED", "查询相册失败: ${e.message}", null)
        }
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            result.success(true)
            return
        }
        pendingResult = result
        // Android 14+ 同时请求 READ_MEDIA_IMAGES 和 READ_MEDIA_VISUAL_USER_SELECTED
        val permissions = getRequiredPermissions()
        ActivityCompat.requestPermissions(this, permissions, 100)
    }

    private fun handleReadImageBytes(path: String, result: MethodChannel.Result) {
        try {
            val bytes = if (path.startsWith("content://")) {
                // 处理 content:// URI（通过 ContentResolver 读取）
                val uri = Uri.parse(path)
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } else {
                // 处理普通文件路径
                val file = File(path)
                if (!file.exists()) {
                    result.error("FILE_NOT_FOUND", "文件不存在: $path", null)
                    return
                }
                file.readBytes()
            }

            if (bytes != null) {
                result.success(bytes)
            } else {
                result.error("READ_FAILED", "无法读取文件: $path", null)
            }
        } catch (e: Exception) {
            result.error("READ_FAILED", "读取文件失败: ${e.message}", null)
        }
    }

    private fun hasStoragePermission(): Boolean {
        val permissions = getRequiredPermissions()
        return permissions.any { permission ->
            ContextCompat.checkSelfPermission(this, permission) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun getRequiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+：同时请求完整访问和部分访问权限
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun queryImageAlbums(): List<Map<String, Any>> {
        val albums = mutableListOf<Map<String, Any>>()
        val contentResolver: ContentResolver = contentResolver

        // Android 10+ 使用 RELATIVE_PATH 替代已废弃的 DATA 列
        val projection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.BUCKET_ID,
                MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.RELATIVE_PATH
            )
        } else {
            arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.BUCKET_ID,
                MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
                MediaStore.Images.Media.DATA
            )
        }

        // 查询所有存储卷，确保不遗漏
        val volumes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 用 Map 按卷名去重，避免 external 和 external_primary 指向同一卷时重复查询
            val volMap = linkedMapOf<String, Uri>()
            // EXTERNAL_CONTENT_URI 默认指向 external_primary
            volMap["external_primary"] = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            // 尝试获取所有卷名并查询每个卷
            try {
                val volNames = MediaStore.getExternalVolumeNames(this)
                for (name in volNames) {
                    if (!volMap.containsKey(name)) {
                        volMap[name] = MediaStore.Images.Media.getContentUri(name)
                    }
                }
            } catch (e: Exception) {
                android.util.Log.w("FrameFlow", "getExternalVolumeNames failed: ${e.message}")
            }
            android.util.Log.d("FrameFlow", "queryImageAlbums: querying ${volMap.size} volume(s): ${volMap.keys}")
            volMap.values.toList()
        } else {
            listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
        }

        for (collection in volumes) {
            android.util.Log.d("FrameFlow", "queryImageAlbums: querying $collection")
            val cursor = contentResolver.query(
                collection,
                projection,
                null,
                null,
                "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} ASC"
            )

            cursor?.use {
                val idIdx = it.getColumnIndex(MediaStore.Images.Media._ID)
                val bucketIdIdx = it.getColumnIndex(MediaStore.Images.Media.BUCKET_ID)
                val bucketNameIdx = it.getColumnIndex(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
                val dataIdx = it.getColumnIndex(MediaStore.Images.Media.DATA)
                val relativePathIdx = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    it.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
                } else {
                    -1
                }

                // 如果连基本列都找不到，直接返回空
                if (bucketIdIdx < 0 || bucketNameIdx < 0) {
                    return@use
                }

                querySingleVolume(it, idIdx, bucketIdIdx, bucketNameIdx, dataIdx, relativePathIdx, albums)
            }
        }

        android.util.Log.d("FrameFlow", "queryImageAlbums: found ${albums.size} albums total")
        albums.sortByDescending { it["imageCount"] as Int }
        return albums.filter { (it["imageCount"] as Int) > 0 }
    }

    private fun querySingleVolume(
        cursor: android.database.Cursor,
        idIdx: Int,
        bucketIdIdx: Int,
        bucketNameIdx: Int,
        dataIdx: Int,
        relativePathIdx: Int,
        albums: MutableList<Map<String, Any>>
    ) {
        val albumMap = mutableMapOf<String, AlbumData>()
        val rootDir = Environment.getExternalStorageDirectory().absolutePath

        while (cursor.moveToNext()) {
            val bucketId = cursor.getLong(bucketIdIdx)
            val bucketName = cursor.getString(bucketNameIdx) ?: "Unknown"

            // 尝试多种方式获取相册路径
            var albumPath: String? = null

            // 1. 优先尝试 RELATIVE_PATH (Android 11+)
            if (relativePathIdx >= 0) {
                val relativePath = cursor.getString(relativePathIdx)
                if (!relativePath.isNullOrBlank()) {
                    val cleanPath = relativePath.trimEnd('/')
                    albumPath = "$rootDir/$cleanPath"
                }
            }

            // 2. 回退到 DATA 列
            if (albumPath == null && dataIdx >= 0) {
                val dataPath = cursor.getString(dataIdx)
                if (!dataPath.isNullOrBlank()) {
                    albumPath = getAlbumDirectoryPath(dataPath)
                }
            }

            // 3. 最后回退：用 bucket name 构造路径
            if (albumPath == null) {
                albumPath = "$rootDir/$bucketName"
            }

            // 按实际目录路径分组（而非 bucket_id），
            // 这样大小写不同的目录（DCIM/Camera vs dcim/Camera）不会合并
            val album = albumMap.getOrPut(albumPath!!) {
                AlbumData(
                    name = bucketName,
                    representativePath = albumPath!!,
                    count = 0,
                    firstImageId = 0
                )
            }
            album.count++

            // 记录第一张图片的 ID（用于缩略图）
            if (album.firstImageId == 0L && idIdx >= 0) {
                album.firstImageId = cursor.getLong(idIdx)
            }
        }

        for ((_, albumData) in albumMap) {
            val thumbnailUri = if (albumData.firstImageId > 0) {
                ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    albumData.firstImageId
                ).toString()
            } else null

            albums.add(
                mapOf(
                    "name" to albumData.name,
                    "path" to albumData.representativePath,
                    "imageCount" to albumData.count,
                    "thumbnailPath" to (thumbnailUri ?: albumData.representativePath)
                )
            )
        }
    }

    private fun getAlbumDirectoryPath(imagePath: String?): String? {
        if (imagePath == null || imagePath.isBlank()) return null
        val lastSlash = imagePath.lastIndexOf('/')
        return if (lastSlash > 0) imagePath.substring(0, lastSlash) else null
    }

    data class AlbumData(
        val name: String,
        val representativePath: String,
        var count: Int,
        var firstImageId: Long
    )
}