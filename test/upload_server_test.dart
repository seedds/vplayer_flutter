import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vplayer/services/playback_state_store.dart';
import 'package:vplayer/services/thumbnail_service.dart';
import 'package:vplayer/services/upload_server.dart';
import 'package:vplayer/services/video_library.dart';

Future<Map<String, Object?>> _postJson(
    HttpClient client, int port, String path, Object body) async {
  final request =
      await client.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(body));
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final parsed = jsonDecode(text) as Map<String, Object?>;
  if (response.statusCode >= 400) {
    throw Exception(parsed['message'] ?? 'HTTP ${response.statusCode}');
  }
  return parsed;
}

Future<Map<String, Object?>> _getJson(
    HttpClient client, int port, String path) async {
  final request =
      await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return jsonDecode(text) as Map<String, Object?>;
}

Future<Map<String, Object?>> _postChunk(HttpClient client, int port,
    Map<String, String> headers, List<int> bytes) async {
  const boundary = 'testboundary123';
  final request =
      await client.postUrl(Uri.parse('http://127.0.0.1:$port/upload/chunk'));
  request.headers.contentType =
      ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
  headers.forEach(request.headers.set);

  request.write('--$boundary\r\n');
  request.write(
      'Content-Disposition: form-data; name="file"; filename="chunk.bin"\r\n');
  request.write('Content-Type: application/octet-stream\r\n\r\n');
  request.add(bytes);
  request.write('\r\n--$boundary--\r\n');

  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  final parsed = jsonDecode(text) as Map<String, Object?>;
  if (response.statusCode >= 400) {
    throw Exception(parsed['message'] ?? 'HTTP ${response.statusCode}');
  }
  return parsed;
}

void main() {
  late Directory tempDir;
  late VideoLibrary library;
  late LocalUploadServer server;
  late HttpClient client;
  late int port;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vplayer_server');
    library = VideoLibrary(tempDir.path);
    server = LocalUploadServer(
      library: library,
      playbackStore: PlaybackStateStore(tempDir.path),
      thumbnails: ThumbnailService(tempDir.path),
    );
    await server.start(port: 0, maxParallelUploads: 3);
    port = server.port!;
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  test('health endpoint', () async {
    final health = await _getJson(client, port, '/health');
    expect(health['ok'], true);
    expect(health['port'], port);
    expect(health['activeUploads'], 0);
  });

  test('serves the upload page', () async {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/'));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    expect(response.statusCode, 200);
    expect(text, contains('<!DOCTYPE html>'));
    expect(text, contains('VPlayer Upload'));
    expect(text, contains('const defaultChunkSize = 1048576;'));
    expect(text, contains('const MAX_PARALLEL_UPLOADS = 3;'));
  });

  test('full chunked upload flow', () async {
    final payload = List<int>.generate(3000, (i) => i % 256);
    final init = await _postJson(client, port, '/upload/init', {
      'fileName': 'test video.mp4',
      'totalSize': payload.length,
    });
    final uploadId = init['uploadId'] as String;
    expect(init['relativePath'], 'test video.mp4');

    // Two chunks, strictly ordered.
    final headersBase = {
      'x-upload-id': uploadId,
      'x-total-chunks': '2',
      'x-total-size': '${payload.length}',
    };
    final first = await _postChunk(client, port,
        {...headersBase, 'x-chunk-index': '0'}, payload.sublist(0, 2000));
    expect(first['receivedBytes'], 2000);

    // Browser retry of an already-processed chunk is re-acknowledged
    // idempotently without appending bytes twice.
    final retried = await _postChunk(client, port,
        {...headersBase, 'x-chunk-index': '0'}, payload.sublist(0, 2000));
    expect(retried['ok'], true);
    expect(retried['receivedBytes'], 2000);

    // An out-of-range chunk is still rejected.
    expect(
      () => _postChunk(client, port, {...headersBase, 'x-chunk-index': '3'},
          payload.sublist(0, 100)),
      throwsException,
    );

    await _postChunk(client, port, {...headersBase, 'x-chunk-index': '1'},
        payload.sublist(2000));

    final complete =
        await _postJson(client, port, '/upload/complete', {'uploadId': uploadId});
    expect(complete['ok'], true);

    final saved = File('${library.videoDirectory}/test video.mp4');
    expect(await saved.exists(), true);
    expect(await saved.length(), payload.length);
    expect((await saved.readAsBytes()).sublist(0, 10),
        payload.sublist(0, 10));
  });

  test('handles full-size 1 MiB chunks', () async {
    // Regression: bodies larger than ~768 KB dropped the connection when the
    // multipart part stream was not fully drained.
    const chunk1MiB = 1024 * 1024;
    final payload = List<int>.generate(chunk1MiB + 500, (i) => (i * 7) % 256);
    final init = await _postJson(client, port, '/upload/init', {
      'fileName': 'big.mkv',
      'totalSize': payload.length,
    });
    final uploadId = init['uploadId'] as String;
    final headersBase = {
      'x-upload-id': uploadId,
      'x-total-chunks': '2',
      'x-total-size': '${payload.length}',
    };
    final first = await _postChunk(client, port,
        {...headersBase, 'x-chunk-index': '0'}, payload.sublist(0, chunk1MiB));
    expect(first['receivedBytes'], chunk1MiB);
    await _postChunk(client, port, {...headersBase, 'x-chunk-index': '1'},
        payload.sublist(chunk1MiB));
    final complete = await _postJson(
        client, port, '/upload/complete', {'uploadId': uploadId});
    expect(complete['ok'], true);
    final saved = File('${library.videoDirectory}/big.mkv');
    expect(await saved.length(), payload.length);
  });

  test('complete rejects incomplete uploads', () async {
    final init = await _postJson(client, port, '/upload/init', {
      'fileName': 'a.mp4',
      'totalSize': 100,
    });
    expect(
      () => _postJson(
          client, port, '/upload/complete', {'uploadId': init['uploadId']}),
      throwsException,
    );
  });

  test('cancel is idempotent', () async {
    final result = await _postJson(
        client, port, '/upload/cancel', {'uploadId': 'nonexistent'});
    expect(result['ok'], true);
  });

  test('library endpoints: folder, list, rename, move, delete', () async {
    final created = await _postJson(client, port, '/library/folder', {
      'parentPath': '',
      'name': 'Shows',
    });
    expect(created['ok'], true);

    await File('${library.videoDirectory}/a.mp4').writeAsString('x');

    final listing = await _getJson(client, port, '/library/list');
    final names = (listing['items'] as List)
        .map((i) => (i as Map)['name'])
        .toList();
    expect(names, ['Shows', 'a.mp4']);

    final renamed = await _postJson(client, port, '/library/rename', {
      'relativePath': 'a.mp4',
      'entryType': 'file',
      'currentPath': '',
      'name': 'b.mp4',
    });
    expect((renamed['item'] as Map)['name'], 'b.mp4');

    final moved = await _postJson(client, port, '/library/move', {
      'currentPath': '',
      'destinationPath': 'Shows',
      'items': [
        {'relativePath': 'b.mp4', 'entryType': 'file'},
      ],
    });
    expect(moved['movedCount'], 1);
    expect(
        await File('${library.videoDirectory}/Shows/b.mp4').exists(), true);

    final deleted = await _postJson(client, port, '/library/delete', {
      'relativePath': 'Shows',
      'entryType': 'folder',
      'currentPath': '',
    });
    expect(deleted['ok'], true);
    expect(await Directory('${library.videoDirectory}/Shows').exists(), false);
  });

  test('init sanitizes traversal paths', () async {
    final init = await _postJson(client, port, '/upload/init', {
      'relativePath': '../../evil.mp4',
      'totalSize': 10,
    });
    expect(init['relativePath'], isNot(contains('..')));
  });

  test('unknown route returns 404', () async {
    final request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port/nope'));
    final response = await request.close();
    expect(response.statusCode, 404);
  });
}
