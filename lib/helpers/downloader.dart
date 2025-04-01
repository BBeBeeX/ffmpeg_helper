import 'dart:io';

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
      List<Future> futures = [];
      List<File> tempFiles = [];

      for (int i = 0; i < threadCount; i++) {
        int start = i * chunkSize;
        int end = (i + 1) * chunkSize - 1;
        if (end >= fileSize) end = fileSize - 1;

        String tempFilePath = "$savePath.part$i";
        tempFiles.add(File(tempFilePath));

        futures.add(_downloadChunk(
          url,
          tempFilePath,
          start,
          end,
          fileSize,
          onProgress,
          queryParameters,
          cancelToken,
        ));
      }

      await Future.wait(futures);

      return await _mergeFiles(tempFiles, savePath);
    } catch (e, stackTrace) {
      print('Download failed: $e');
      print(stackTrace);
      return false;
    }
  }

  /// 单独处理每个分片下载，避免 Dio 失败时影响整个流程
  static Future<void> _downloadChunk(
    String url,
    String filePath,
    int start,
    int end,
    int fileSize,
    void Function(int received, int total)? onProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  ) async {
    try {
      Dio dio = Dio();
      await dio.download(
        url,
        filePath,
        options: Options(headers: {"Range": "bytes=$start-$end"}),
        queryParameters: queryParameters, // 添加查询参数
        cancelToken: cancelToken, // 添加取消支持
        onReceiveProgress: (received, total) {
          onProgress?.call(received, fileSize);
        },
      );
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        print("Download canceled for range $start-$end");
      } else {
        print("Chunk download failed for range $start-$end: $e");
        throw Exception("Download chunk failed for range $start-$end");
      }
    }
  }

  /// 合并多个分片到最终文件
  static Future<bool> _mergeFiles(
      List<File> tempFiles, String finalPath) async {
    try {
      File finalFile = File(finalPath);
      IOSink sink = finalFile.openWrite(mode: FileMode.write);
      for (var tempFile in tempFiles) {
        await sink.addStream(tempFile.openRead());
        await tempFile.delete();
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
