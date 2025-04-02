import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';

class Downloader {
  static Future<bool> multiThreadDownload({
    required String url,
    required String savePath,
    int threadCount = 16,
    void Function(int received, int total)? onProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) async {
    try {
      final saveDir = Directory(
          savePath.substring(0, savePath.lastIndexOf(Platform.pathSeparator)));
      if (!await saveDir.exists()) {
        print("Creating directory: ${saveDir.path}");
        await saveDir.create(recursive: true);
      }

      print("Getting file size for $url");
      int fileSize = await getFileSize(url, queryParameters);

      if (fileSize <= 0) {
        print("Range support detected but unknown file size.");
        return false;
      } else {
        print("File size determined: $fileSize bytes");
      }

      int chunkSize = (fileSize / threadCount).ceil();
      List<Future<bool>> futures = [];
      List<File> tempFiles = [];
      Map<int, int> chunkReceived = {};

      final progressReceivePort = ReceivePort();
      int totalReceived = 0;

      progressReceivePort.listen((message) {
        if (message is Map && message['type'] == 'progress') {
          int chunkIndex = message['index'] as int;
          int received = message['received'] as int;

          chunkReceived[chunkIndex] = received;

          totalReceived = chunkReceived.values.fold(0, (a, b) => a + b);
          onProgress?.call(totalReceived, fileSize);
        }
      });

      for (int i = 0; i < threadCount; i++) {
        int start = i * chunkSize;
        int end = (i + 1) * chunkSize - 1;
        if (end >= fileSize) end = fileSize - 1;

        String tempFilePath = "$savePath.part$i";
        tempFiles.add(File(tempFilePath));

        futures.add(_downloadChunkWithIsolate(
          DownloadChunkParams(
            url: url,
            filePath: tempFilePath,
            start: start,
            end: end,
            fileSize: fileSize,
            progressPort: progressReceivePort.sendPort,
            index: i,
            queryParameters: queryParameters,
          ),
        ));
      }

      List<bool> results = await Future.wait(futures);
      progressReceivePort.close();

      if (results.contains(false)) {
        print("Some chunks failed to download");
        return false;
      }

      print("All chunks downloaded successfully, merging files");
      return await _mergeFiles(tempFiles, savePath);
    } catch (e, stackTrace) {
      print('Download failed: $e');
      print(stackTrace);
      return false;
    }
  }

  static Future<int> getFileSize(
      String url, Map<String, dynamic>? queryParameters,
      {int maxRetries = 5,
      Duration retryDelay = const Duration(seconds: 2)}) async {
    Dio dio = Dio();
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        print("Attempt ${attempt + 1}: Getting file size for $url");
        Response response = await dio.head(url,
            queryParameters: queryParameters,
            options: Options(
                validateStatus: (status) => status != null && status < 500));

        if (response.statusCode == 200) {
          final contentLength =
              response.headers.value(HttpHeaders.contentLengthHeader);
          final fileSize = int.tryParse(contentLength ?? '0') ?? 0;

          return fileSize;
        }
      } catch (e) {
        ;
      }

      attempt++;
      await Future.delayed(const Duration(seconds: 5));
    }
    print("Failed to retrieve file size after $maxRetries attempts");
    return 0;
  }

  static Future<bool> _mergeFiles(
      List<File> tempFiles, String finalPath) async {
    try {
      File finalFile = File(finalPath);
      IOSink sink = finalFile.openWrite(mode: FileMode.write);
      for (var tempFile in tempFiles) {
        if (await tempFile.exists()) {
          await sink.addStream(tempFile.openRead());
          await tempFile.delete();
        } else {
          throw Exception('Temporary file does not exist: ${tempFile.path}');
        }
      }

      try {
        await sink.flush();
        await sink.close();
      } catch (e) {
        print("Error closing file sink: $e");
      }

      return true;
    } catch (e) {
      print("Failed to merge files: $e");
      return false;
    }
  }

  static Future<bool> _downloadChunkWithIsolate(
      DownloadChunkParams params) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_isolateDownloadChunk, [receivePort.sendPort, params]);

    final result = await receivePort.first as bool;
    receivePort.close();
    return result;
  }

  static void _isolateDownloadChunk(List<dynamic> args) async {
    SendPort sendPort = args[0] as SendPort;
    DownloadChunkParams params = args[1] as DownloadChunkParams;

    bool success = false;
    int maxRetries = 50;
    int attempt = 0;

    // 初始文件状态检查
    File file = File(params.filePath);
    int downloadedBytes = file.existsSync() ? file.lengthSync() : 0;
    int totalBytes = params.end - params.start + 1;
    String backupFilePath = "${params.filePath}.bak";
    String tempFilePath = "${params.filePath}.temp";

    // 如果已下载完成，直接返回成功
    if (downloadedBytes >= totalBytes) {
      print("Chunk already fully downloaded: ${params.filePath}");
      sendPort.send(true);
      Isolate.exit(sendPort, true);
    }

    while (attempt < maxRetries) {
      try {
        // 备份已下载内容
        await _backupExistingFile(file, backupFilePath, downloadedBytes);

        // 计算续传位置
        int currentStart = params.start + downloadedBytes;
        print(
            "Downloading range: $currentStart-${params.end} (attempt ${attempt + 1}/$maxRetries)");

        // 开始下载新内容
        try {
          await _downloadChunkPart(
              params, tempFilePath, currentStart, downloadedBytes);

          // 处理文件合并
          int newSize = await _mergeDownloadedParts(
              file, tempFilePath, backupFilePath, downloadedBytes);

          // 检查下载是否完成
          if (newSize >= totalBytes) {
            success = true;
            break;
          } else {
            print("Incomplete download: $newSize of $totalBytes bytes");
            downloadedBytes = newSize;
          }
        } catch (e) {
          print("Download chunk part failed: $e");

          String errorMsg = e.toString().toLowerCase();
          bool isNetworkError = errorMsg.contains('socket') ||
              errorMsg.contains('connection') ||
              errorMsg.contains('network') ||
              errorMsg.contains('timeout') ||
              errorMsg.contains('stalled');

          if (isNetworkError) {
            throw e;
          } else {
            File tempFile = File(tempFilePath);
            if (await tempFile.exists() && await tempFile.length() > 0) {
              throw e;
            } else {
              throw e;
            }
          }
        }
      } catch (e) {
        attempt++;
        print("Download failed (${params.start}-${params.end}): $e");

        // 尝试恢复备份
        await _restoreBackup(file, backupFilePath);

        if (attempt >= maxRetries) {
          print("Max retries reached for range ${params.start}-${params.end}");
          break;
        } else {
          // Dynamic backoff based on attempt number and error type
          String errorMsg = e.toString().toLowerCase();
          bool isNetworkTimeout =
              errorMsg.contains('timeout') || errorMsg.contains('stalled');

          // Network timeouts get longer backoffs
          int backoffSeconds = isNetworkTimeout
              ? (attempt < 5 ? attempt * 2 : 10 + (attempt ~/ 2))
              : (attempt < 5 ? attempt : 5 + (attempt ~/ 5));

          backoffSeconds = backoffSeconds > 30 ? 30 : backoffSeconds;

          print(
              "Retrying... Attempt $attempt of $maxRetries. Waiting $backoffSeconds seconds");
          await Future.delayed(Duration(seconds: backoffSeconds));

          // For persistent timeouts, let's try validating the connection
          if (isNetworkTimeout && attempt % 5 == 0) {
            await Future.delayed(Duration(seconds: 10)); // Longer pause
          }
        }
      } finally {
        await _cleanupFile(tempFilePath);
      }
    }

    // 最终清理
    await _cleanupFile(backupFilePath);

    sendPort.send(success);
    Isolate.exit(sendPort, success);
  }

  static Future<void> _downloadChunkPart(
    DownloadChunkParams params,
    String tempFilePath,
    int currentStart,
    int downloadedBytes,
  ) async {
    Dio dio = Dio();
    final completer = Completer<void>();
    final cancelToken = CancelToken();
    int currentReceivedBytes = downloadedBytes;

    try {
      final response = await dio.download(
        params.url,
        tempFilePath,
        queryParameters: params.queryParameters,
        options: Options(
          headers: {"Range": "bytes=$currentStart-${params.end}"},
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
          // contentType: 'application/octet-stream',
        ),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          currentReceivedBytes = downloadedBytes + received;
          params.progressPort.send({
            'type': 'progress',
            'index': params.index,
            'received': currentReceivedBytes,
          });
        },
      );

      File tempFile = File(tempFilePath);
      if (await tempFile.exists()) {
        int fileSize = await tempFile.length();
        if (fileSize == 0) {
          throw Exception("Downloaded file is empty: $tempFilePath");
        }
      } else {
        throw Exception("Download completed but file not found: $tempFilePath");
      }

      completer.complete();
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(Exception("Download failed: $e"));
      }
    } finally {
      try {
        dio.close(force: true);
      } catch (_) {}
    }

    return completer.future;
  }

  static Future<int> _mergeDownloadedParts(File file, String tempPath,
      String backupPath, int downloadedBytes) async {
    File tempFile = File(tempPath);
    if (!await tempFile.exists()) return downloadedBytes;

    try {
      if (downloadedBytes > 0) {
        // 有已下载内容，需要合并
        File backupFile = File(backupPath);
        IOSink sink = file.openWrite(mode: FileMode.write);

        // 合并两部分内容
        try {
          await sink.addStream(backupFile.openRead());
          await sink.addStream(tempFile.openRead());
        } finally {
          await sink.close();
        }

        // 清理临时文件
        await tempFile.delete();
        await backupFile.delete();

        print("Successfully merged downloaded chunks");
      } else {
        if (await file.exists()) {
          await file.delete();
        }
        await tempFile.rename(file.path);
      }

      return await file.length();
    } catch (e) {
      throw e;
    }
  }

  static Future<void> _restoreBackup(File file, String backupPath) async {
    File backupFile = File(backupPath);
    if (!await backupFile.exists()) return;

    try {
      if (await backupFile.length() < await file.length()) {
        print("Backup file is incomplete, skipping restore.");
        return;
      }

      if (await file.exists()) {
        await file.delete();
      }
      await backupFile.copy(file.path);
      print("Restored backup file for retry");
    } catch (e) {
      print("Failed to restore backup: $e");
    }
  }

  static Future<void> _cleanupFile(String filePath) async {
    try {
      File file = File(filePath);
      if (!await file.exists()) return;

      await Future.delayed(Duration(milliseconds: 500));

      for (int i = 0; i < 3; i++) {
        try {
          await file.delete();
          print("Successfully deleted $filePath file");
          return;
        } catch (e) {
          print("Delete file $filePath attempt ${i + 1} failed: $e");
          await Future.delayed(Duration(seconds: 1));
        }
      }

      print("Unable to delete $filePath file: $filePath");
    } catch (e) {
      print("Failed to clean up $filePath file: $e");
    }
  }

  static Future<void> _backupExistingFile(
      File file, String backupPath, int downloadedBytes) async {
    if (downloadedBytes <= 0) return;

    try {
      await file.copy(backupPath);
      print("Backed up partially downloaded file: $backupPath");
    } catch (e) {
      print("Failed to backup file: $e");
    }
  }
}

class DownloadChunkParams {
  final String url;
  final String filePath;
  final int start;
  final int end;
  final int fileSize;
  final SendPort progressPort;
  final Map<String, dynamic>? queryParameters;
  final int index;

  DownloadChunkParams({
    required this.url,
    required this.filePath,
    required this.start,
    required this.end,
    required this.fileSize,
    required this.progressPort,
    this.queryParameters,
    required this.index,
  });
}
