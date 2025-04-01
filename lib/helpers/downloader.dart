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
      int fileSize = await getFileSize(url, queryParameters);
      if (fileSize == 0) {
        throw Exception('Unable to retrieve file size');
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
        throw Exception('Some chunks failed to download');
      }

      return await _mergeFiles(tempFiles, savePath);
    } catch (e, stackTrace) {
      print('Download failed: $e');
      print(stackTrace);
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
    int maxRetries = 20;
    int attempt = 0;

    // 检查已下载的字节数
    File file = File(params.filePath);
    int downloadedBytes = file.existsSync() ? file.lengthSync() : 0;
    int totalBytes = params.end - params.start + 1;

    // 在重试之前备份路径
    String backupFilePath = "${params.filePath}.bak";

    while (attempt < maxRetries) {
      Timer? timeoutTimer;
      Completer<void> downloadCompleter = Completer<void>();

      try {
        timeoutTimer = Timer(Duration(seconds: 20), () {
          if (!downloadCompleter.isCompleted) {
            downloadCompleter.completeError(TimeoutException(
                "Download stalled for range ${params.start}-${params.end}, retrying..."));
          }
        });

        if (downloadedBytes >= totalBytes) {
          print("Chunk already fully downloaded: ${params.filePath}");
          success = true;
          break;
        }

        // 如果有部分已下载，先备份
        if (downloadedBytes > 0) {
          try {
            // 创建备份
            await file.copy(backupFilePath);
            print("Backed up partially downloaded file: $backupFilePath");
          } catch (e) {
            print("Failed to backup file: $e");
          }
        }

        // 计算新的起始位置
        int currentStart = params.start + downloadedBytes;
        print("Continuing download from byte $currentStart to ${params.end}");

        // 使用临时文件下载新内容
        String tempFilePath = "${params.filePath}.temp";

        Dio().download(
          params.url,
          tempFilePath,
          options: Options(
            headers: {"Range": "bytes=$currentStart-${params.end}"},
          ),
          onReceiveProgress: (received, total) {
            timeoutTimer?.cancel();
            timeoutTimer = Timer(Duration(seconds: 20), () {
              if (!downloadCompleter.isCompleted) {
                downloadCompleter
                    .completeError(TimeoutException("Download stalled"));
              }
            });

            params.progressPort.send({
              'type': 'progress',
              'index': params.index,
              'received': downloadedBytes + received,
            });
          },
        ).then((_) async {
          // 下载完成后，合并文件
          if (downloadedBytes > 0) {
            // 如果有已下载内容，需要合并
            File tempFile = File(tempFilePath);
            if (await tempFile.exists()) {
              try {
                // 打开备份文件用于读取
                File backupFile = File(backupFilePath);
                // 创建最终文件
                IOSink sink = file.openWrite(mode: FileMode.write);

                // 先写入备份数据
                await sink.addStream(backupFile.openRead());
                // 再写入新下载的数据
                await sink.addStream(tempFile.openRead());
                await sink.close();

                // 清理临时文件
                await tempFile.delete();
                await backupFile.delete();

                // 更新已下载字节数
                downloadedBytes = await file.length();

                print("Successfully merged downloaded chunks");
              } catch (e) {
                print("Error merging files: $e");
                if (!downloadCompleter.isCompleted) {
                  downloadCompleter.completeError(e);
                }
                return;
              }
            }
          } else {
            // 如果是首次下载，直接重命名临时文件
            File tempFile = File(tempFilePath);
            if (await tempFile.exists()) {
              await tempFile.rename(params.filePath);
              downloadedBytes = await File(params.filePath).length();
            }
          }

          if (!downloadCompleter.isCompleted) {
            downloadCompleter.complete();
          }
        }).catchError((error) {
          if (!downloadCompleter.isCompleted) {
            downloadCompleter.completeError(error);
          }
        });

        await downloadCompleter.future;

        // 验证下载是否完成
        if (await file.exists()) {
          int finalSize = await file.length();
          if (finalSize >= totalBytes) {
            success = true;
            break;
          } else {
            print(
                "Downloaded file size ($finalSize bytes) is less than expected ($totalBytes bytes)");
            downloadedBytes = finalSize; // 更新已下载大小以便下次继续
          }
        }
      } catch (e) {
        attempt++;
        print(
            "Chunk download failed for range ${params.start}-${params.end}: $e");

        // 如果下载失败，检查备份是否存在并恢复
        File backupFile = File(backupFilePath);
        if (await backupFile.exists()) {
          try {
            // 恢复备份
            if (await file.exists()) {
              await file.delete();
            }
            await backupFile.copy(params.filePath);
            print("Restored backup file for retry");
          } catch (restoreError) {
            print("Failed to restore backup: $restoreError");
          }
        }

        if (attempt >= maxRetries) {
          print("Max retries reached for range ${params.start}-${params.end}");
          success = false;
        } else {
          print("Retrying... Attempt $attempt of $maxRetries");
          await Future.delayed(Duration(seconds: 1));
        }
      } finally {
        timeoutTimer?.cancel();

        // 清理可能遗留的临时文件
        try {
          File tempFile = File("${params.filePath}.temp");
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (e) {
          print("Failed to clean up temp file: $e");
        }
      }
    }

    // 清理备份文件
    try {
      File backupFile = File(backupFilePath);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
    } catch (e) {
      print("Failed to clean up backup file: $e");
    }

    sendPort.send(success);
    Isolate.exit(sendPort, success);
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
      await sink.close();
      return true;
    } catch (e) {
      print("Failed to merge files: $e");
      return false;
    }
  }

  static Future<int> getFileSize(
      String url, Map<String, dynamic>? queryParameters,
      {int maxRetries = 3,
      Duration retryDelay = const Duration(seconds: 2)}) async {
    Dio dio = Dio();
    int attempt = 0;

    while (attempt < maxRetries) {
      try {
        Response response =
            await dio.head(url, queryParameters: queryParameters);
        return int.tryParse(
                response.headers.value(HttpHeaders.contentLengthHeader) ??
                    '0') ??
            0;
      } catch (e) {
        attempt++;
        print("Attempt $attempt: Failed to get file size: $e");
        if (attempt >= maxRetries) {
          throw Exception(
              'Failed to retrieve file size after $maxRetries attempts.');
        }
        await Future.delayed(retryDelay);
      }
    }

    return 0;
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
