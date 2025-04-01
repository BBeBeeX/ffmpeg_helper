import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';

class Downloader {
  static Future<bool> multiThreadDownload({
    required String url,
    required String savePath,
    int threadCount = 8,
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

      final progressReceivePort = ReceivePort();
      int totalReceived = 0;

      progressReceivePort.listen((message) {
        if (message is Map && message['type'] == 'progress') {
          totalReceived += message['received'] as int;
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

  /// 使用 Isolate 下载单个分片
  static Future<bool> _downloadChunkWithIsolate(
      DownloadChunkParams params) async {
    final receivePort = ReceivePort();
    await Isolate.spawn(_isolateDownloadChunk, [receivePort.sendPort, params]);

    final result = await receivePort.first as bool;
    receivePort.close();
    return result;
  }

  /// Isolate 中执行的下载任务
  static void _isolateDownloadChunk(List<dynamic> args) async {
    SendPort sendPort = args[0] as SendPort;
    DownloadChunkParams params = args[1] as DownloadChunkParams;

    bool success = false;
    try {
      await Dio().download(
        params.url,
        params.filePath,
        options:
            Options(headers: {"Range": "bytes=${params.start}-${params.end}"}),
        queryParameters: params.queryParameters,
        onReceiveProgress: (received, total) {
          params.progressPort.send({
            'type': 'progress',
            'received': received,
          });
        },
      );
      success = true;
    } catch (e) {
      print(
          "Chunk download failed for range ${params.start}-${params.end}: $e");
      success = false;
    } finally {
      sendPort.send(success);
      Isolate.exit(sendPort, success);
    }
  }

  /// 合并多个分片到最终文件
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

  /// 获取文件大小
  static Future<int> getFileSize(
      String url, Map<String, dynamic>? queryParameters) async {
    try {
      Dio dio = Dio();
      Response response = await dio.head(url, queryParameters: queryParameters);
      return int.tryParse(
              response.headers.value(HttpHeaders.contentLengthHeader) ?? '0') ??
          0;
    } catch (e) {
      print("Failed to get file size: $e");
      return 0;
    }
  }
}

/// 用于传递下载参数到 Isolate 的类
class DownloadChunkParams {
  final String url;
  final String filePath;
  final int start;
  final int end;
  final int fileSize;
  final SendPort progressPort;
  final Map<String, dynamic>? queryParameters;

  DownloadChunkParams({
    required this.url,
    required this.filePath,
    required this.start,
    required this.end,
    required this.fileSize,
    required this.progressPort,
    this.queryParameters,
  });
}
