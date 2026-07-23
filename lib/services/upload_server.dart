import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_multipart/shelf_multipart.dart';

import '../models/library_item.dart';
import '../models/upload_activity.dart';
import 'playback_state_store.dart';
import 'thumbnail_service.dart';
import 'upload_page.dart';
import 'upload_settings_store.dart';
import 'video_library.dart';

const defaultServerPort = 8081;
const chunkSize = 1024 * 1024;

class _UploadSession {
  _UploadSession({
    required this.uploadId,
    required this.fileName,
    required this.finalPath,
    required this.relativePath,
    required this.tempPath,
    required this.totalSize,
  });

  final String uploadId;
  final String fileName;
  final String finalPath;
  final String relativePath;
  final String tempPath;
  final int totalSize;
  int receivedBytes = 0;
  int expectedChunkIndex = 0;
  int? totalChunks;
}

class _HandlerError implements Exception {
  _HandlerError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Local HTTP server exposing the browser upload page, chunked upload
/// endpoints, and library management endpoints. Binds to 0.0.0.0.
///
/// Protocol matches the original VPlayer server exactly, so the ported
/// upload page works unchanged.
class LocalUploadServer {
  LocalUploadServer({
    required this.library,
    required this.playbackStore,
    required this.thumbnails,
  });

  final VideoLibrary library;
  final PlaybackStateStore playbackStore;
  final ThumbnailService thumbnails;

  HttpServer? _server;
  int? _port;
  int _maxParallelUploads = defaultMaxParallelUploads;
  final _uploads = <String, _UploadSession>{};

  void Function(UploadActivity activity)? onActivity;
  Future<void> Function()? onLibraryChanged;

  bool get isRunning => _server != null;
  int? get port => _port;

  void setMaxParallelUploads(int value) {
    _maxParallelUploads = clampMaxParallelUploads(value);
  }

  Future<void> start({required int port, required int maxParallelUploads}) async {
    _maxParallelUploads = clampMaxParallelUploads(maxParallelUploads);

    if (_server != null && _port == port) {
      _emitActivity(UploadStatus.idle, 'Server ready on port $port.');
      return;
    }

    await stop();
    await library.ensureAppDirectories();
    await library.clearTempUploads();

    final server =
        await shelf_io.serve(_handleRequest, InternetAddress.anyIPv4, port);
    _server = server;
    _port = server.port;
    _emitActivity(UploadStatus.idle, 'Server ready on port ${server.port}.');
  }

  Future<void> stop() async {
    final server = _server;
    if (server != null) {
      _server = null;
      await server.close(force: true);
    }

    final activeUploads = _uploads.values.toList();
    _uploads.clear();
    _port = null;

    for (final upload in activeUploads) {
      try {
        final file = File(upload.tempPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    _emitActivity(UploadStatus.stopped, 'Server stopped.');
  }

  // ---- activity -----------------------------------------------------------

  List<ActiveUploadRow> _buildUploadRows(int updatedAt) => [
        for (final session in _uploads.values)
          ActiveUploadRow(
            uploadId: session.uploadId,
            fileName: session.relativePath,
            message: session.receivedBytes > 0
                ? 'Uploading ${session.fileName}'
                : 'Preparing ${session.fileName}',
            updatedAt: updatedAt,
            receivedBytes: session.receivedBytes > session.totalSize
                ? session.totalSize
                : session.receivedBytes,
            totalBytes: session.totalSize,
          ),
      ];

  void _emitActivity(UploadStatus statusWhenIdle, String messageWhenIdle) {
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    final activeUploads = _buildUploadRows(updatedAt);

    if (activeUploads.isEmpty) {
      onActivity?.call(UploadActivity(
        status: statusWhenIdle,
        message: messageWhenIdle,
        updatedAt: updatedAt,
      ));
      return;
    }

    final receivedBytes =
        activeUploads.fold<int>(0, (sum, u) => sum + u.receivedBytes);
    final totalBytes =
        activeUploads.fold<int>(0, (sum, u) => sum + u.totalBytes);
    final isPreparingOnly = activeUploads.every((u) => u.receivedBytes == 0);

    onActivity?.call(UploadActivity(
      status: UploadStatus.receiving,
      message:
          '${isPreparingOnly ? 'Preparing' : 'Uploading'} ${activeUploads.length} '
          'file${activeUploads.length == 1 ? '' : 's'}',
      updatedAt: updatedAt,
      activeUploads: activeUploads,
      receivedBytes: receivedBytes,
      totalBytes: totalBytes,
    ));
  }

  // ---- request plumbing ---------------------------------------------------

  Response _json(Object body, [int statusCode = 200]) => Response(
        statusCode,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );

  Response _html(String body) => Response.ok(
        body,
        headers: {'Content-Type': 'text/html; charset=utf-8'},
      );

  static String _readString(Object? input, String fieldName) {
    if (input is! String || input.trim().isEmpty) {
      throw _HandlerError('Missing $fieldName.');
    }
    return input.trim();
  }

  static num _readNumber(Object? input, String fieldName) {
    if (input is! num || !input.isFinite) {
      throw _HandlerError('Missing $fieldName.');
    }
    return input;
  }

  static String? _readOptionalString(Object? input) {
    if (input is! String) return null;
    final trimmed = input.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _readHeader(Request request, String key) {
    final value = request.headers[key.toLowerCase()];
    if (value == null || value.trim().isEmpty) {
      throw _HandlerError('Missing $key.');
    }
    return value.trim();
  }

  static int _readHeaderNumber(Request request, String key) {
    final parsed = int.tryParse(_readHeader(request, key));
    if (parsed == null) throw _HandlerError('Invalid $key.');
    return parsed;
  }

  Future<Map<String, Object?>> _readJsonBody(Request request) async {
    final text = await request.readAsString();
    if (text.isEmpty) return {};
    final parsed = jsonDecode(text);
    return parsed is Map<String, Object?> ? parsed : {};
  }

  Future<Map<String, Object?>> _libraryListing(String? path) async {
    final normalizedPath = VideoLibrary.normalizeLibraryDirectoryPath(path);
    final items = await library
        .listLibraryItems(normalizedPath.isEmpty ? null : normalizedPath);
    return {
      'path': normalizedPath,
      'items': [for (final item in items) item.toServerJson()],
    };
  }

  Future<Response> _handleRequest(Request request) async {
    try {
      final path = '/${request.url.path}';
      final method = request.method;

      if (method == 'GET' && path == '/') {
        return _html(buildUploadPage(
          chunkSize: chunkSize,
          maxParallelUploads: _maxParallelUploads,
        ));
      }
      if (method == 'GET' && path == '/health') {
        return _json({
          'ok': true,
          'port': _port,
          'activeUploads': _uploads.length,
        });
      }
      if (method == 'POST' && path == '/upload/init') {
        return await _guard(() => _handleInit(request));
      }
      if (method == 'GET' && path == '/library/list') {
        return await _guard(() async =>
            _json(await _libraryListing(request.url.queryParameters['path'])));
      }
      if (method == 'POST' && path == '/library/folder') {
        return await _guard(() => _handleCreateFolder(request));
      }
      if (method == 'POST' && path == '/library/delete') {
        return await _guard(() => _handleDelete(request));
      }
      if (method == 'POST' && path == '/library/rename') {
        return await _guard(() => _handleRename(request));
      }
      if (method == 'POST' && path == '/library/move') {
        return await _guard(() => _handleMove(request));
      }
      if (method == 'POST' && path == '/upload/chunk') {
        return await _guard(() => _handleChunk(request));
      }
      if (method == 'POST' && path == '/upload/complete') {
        return await _guard(() => _handleComplete(request));
      }
      if (method == 'POST' && path == '/upload/cancel') {
        return await _guard(() => _handleCancel(request));
      }

      return _json({'message': 'Route not found.'}, 404);
    } catch (error) {
      return _json({'message': _errorMessage(error)}, 500);
    }
  }

  Future<Response> _guard(Future<Response> Function() handler) async {
    try {
      return await handler();
    } catch (error) {
      return _json({'message': _errorMessage(error)}, 400);
    }
  }

  static String _errorMessage(Object error) {
    if (error is _HandlerError) return error.message;
    if (error is Exception) {
      final text = error.toString();
      return text.startsWith('Exception: ') ? text.substring(11) : text;
    }
    return 'Unknown server error.';
  }

  // ---- upload endpoints ---------------------------------------------------

  Future<Response> _handleInit(Request request) async {
    final body = await _readJsonBody(request);
    final relativePath = _readOptionalString(body['relativePath']) ??
        _readString(body['fileName'], 'fileName');
    final totalSize = _readNumber(body['totalSize'], 'totalSize');

    if (totalSize <= 0) {
      throw _HandlerError('Upload must contain at least one byte.');
    }

    final target = await library.createUploadTarget(relativePath);
    final uploadId =
        '${DateTime.now().millisecondsSinceEpoch}-${VideoLibrary.randomToken()}';

    _uploads[uploadId] = _UploadSession(
      uploadId: uploadId,
      fileName: target.fileName,
      finalPath: target.finalPath,
      relativePath: target.relativePath,
      tempPath: target.tempPath,
      totalSize: totalSize.toInt(),
    );

    _emitActivity(UploadStatus.receiving, 'Preparing ${target.fileName}');

    return _json({
      'uploadId': uploadId,
      'fileName': target.fileName,
      'relativePath': target.relativePath,
      'chunkSize': chunkSize,
    });
  }

  /// Extracts the form field `name` from a part's `content-disposition`
  /// header (e.g. `form-data; name="file"; filename="chunk.bin"` -> `file`).
  static String? _partFieldName(Map<String, String> headers) {
    final disposition = headers['content-disposition'];
    if (disposition == null) return null;
    final match =
        RegExp(r'name="([^"]*)"|name=([^\s;]+)').firstMatch(disposition);
    return match?.group(1) ?? match?.group(2);
  }

  Future<Response> _handleChunk(Request request) async {
    final uploadId = _readHeader(request, 'x-upload-id');
    final chunkIndex = _readHeaderNumber(request, 'x-chunk-index');
    final totalChunks = _readHeaderNumber(request, 'x-total-chunks');
    final totalSize = _readHeaderNumber(request, 'x-total-size');
    final session = _uploads[uploadId];

    // Drain the body before any validation error so the connection is left
    // in a clean state (otherwise clients may see a dropped connection and
    // retry, compounding the problem).
    // The browser sends the chunk as multipart form data ("file" field).
    // Important: consume ALL parts to the end — breaking out of the stream
    // early leaves the request body undrained, which drops the connection
    // before the response is written (observed with bodies >~768 KB).
    List<int>? chunkBytes;
    final multipart = request.multipart();
    if (multipart != null) {
      await for (final part in multipart.parts) {
        final bytes = await part.readBytes();
        // Keep only the "file" field's bytes, but keep draining every part to
        // the end (see gotcha above) rather than trusting part order.
        if (chunkBytes == null && _partFieldName(part.headers) == 'file') {
          chunkBytes = bytes;
        }
      }
    } else {
      chunkBytes = await request
          .read()
          .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
          .then((b) => b.takeBytes());
    }

    if (session == null) throw _HandlerError('Upload session not found.');
    if (session.totalSize != totalSize) {
      throw _HandlerError('Upload size mismatch.');
    }
    if (totalChunks <= 0) {
      throw _HandlerError('Invalid chunk count.');
    }
    // Pin the chunk count to the session on first sighting; a client must not
    // change how many chunks it claims part-way through an upload.
    session.totalChunks ??= totalChunks;
    if (session.totalChunks != totalChunks) {
      throw _HandlerError('Upload chunk count mismatch.');
    }
    if (chunkIndex < 0 || chunkIndex >= totalChunks) {
      throw _HandlerError('Chunk index out of range.');
    }

    // Idempotency: browsers may transparently retry a POST when a keep-alive
    // connection drops after the request was already processed. If we've
    // already consumed this chunk, re-acknowledge it instead of failing.
    if (chunkIndex < session.expectedChunkIndex) {
      return _json({
        'ok': true,
        'receivedBytes': session.receivedBytes,
        'totalBytes': session.totalSize,
      });
    }

    if (chunkIndex != session.expectedChunkIndex) {
      throw _HandlerError(
          'Unexpected chunk order. Expected chunk ${session.expectedChunkIndex}.');
    }

    if (chunkBytes == null || chunkBytes.isEmpty) {
      throw _HandlerError('Uploaded chunk file missing.');
    }
    if (chunkBytes.length > chunkSize) {
      throw _HandlerError('Chunk exceeds maximum chunk size.');
    }
    if (session.receivedBytes + chunkBytes.length > session.totalSize) {
      throw _HandlerError('Chunk exceeds declared upload size.');
    }

    final tempFile = File(session.tempPath);
    await tempFile.writeAsBytes(
      chunkBytes,
      mode: session.receivedBytes > 0 ? FileMode.append : FileMode.write,
      flush: false,
    );
    session.receivedBytes += chunkBytes.length;
    session.expectedChunkIndex += 1;

    _emitActivity(UploadStatus.receiving, 'Uploading ${session.fileName}');

    return _json({
      'ok': true,
      'receivedBytes': session.receivedBytes,
      'totalBytes': session.totalSize,
    });
  }

  Future<Response> _handleComplete(Request request) async {
    final body = await _readJsonBody(request);
    final uploadId = _readString(body['uploadId'], 'uploadId');
    final session = _uploads[uploadId];

    if (session == null) throw _HandlerError('Upload session not found.');
    if (session.receivedBytes != session.totalSize) {
      throw _HandlerError('Upload is incomplete.');
    }

    final targetType = await FileSystemEntity.type(session.finalPath);
    if (targetType == FileSystemEntityType.directory) {
      throw _HandlerError('A folder with that name already exists.');
    }
    if (targetType != FileSystemEntityType.notFound) {
      await File(session.finalPath).delete();
    }

    await File(session.tempPath).rename(session.finalPath);

    _uploads.remove(uploadId);
    _emitActivity(UploadStatus.complete, 'Saved ${session.relativePath}');

    await onLibraryChanged?.call();
    return _json({'ok': true, 'fileName': session.fileName});
  }

  Future<Response> _handleCancel(Request request) async {
    final body = await _readJsonBody(request);
    final uploadId = _readString(body['uploadId'], 'uploadId');
    final session = _uploads.remove(uploadId);

    if (session != null) {
      try {
        final file = File(session.tempPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      _emitActivity(UploadStatus.cancelled, 'Cancelled ${session.fileName}');
    }

    return _json({'ok': true});
  }

  // ---- library endpoints --------------------------------------------------

  Future<Response> _handleCreateFolder(Request request) async {
    final body = await _readJsonBody(request);
    final parentPath = VideoLibrary.normalizeLibraryDirectoryPath(
        _readOptionalString(body['parentPath']));
    final name = _readString(body['name'], 'name');
    final folder = await library.createLibraryFolder(
        parentPath.isEmpty ? null : parentPath, name);

    _emitActivity(UploadStatus.idle, 'Created folder ${folder.name}');
    await onLibraryChanged?.call();

    return _json({
      'ok': true,
      'folder': folder.toServerJson(),
      ...await _libraryListing(parentPath.isEmpty ? null : parentPath),
    });
  }

  String _readEntryType(Object? input) {
    final entryType = _readString(input, 'entryType');
    if (entryType != 'file' && entryType != 'folder') {
      throw _HandlerError('Invalid entryType.');
    }
    return entryType;
  }

  Future<void> _cleanupPlaybackArtifacts(List<LibraryItem> videos) async {
    if (videos.isEmpty) return;
    await playbackStore.clearProgressFor(videos.map((v) => v.path));
    for (final video in videos) {
      try {
        await thumbnails.deleteThumbnailForVideo(video);
      } catch (_) {}
    }
  }

  Future<Response> _handleDelete(Request request) async {
    final body = await _readJsonBody(request);
    final relativePath = _readString(body['relativePath'], 'relativePath');
    final entryType = _readEntryType(body['entryType']);
    final currentPath = VideoLibrary.normalizeLibraryDirectoryPath(
        _readOptionalString(body['currentPath']));

    final target = await library.getLibraryItem(relativePath, entryType);
    if (target == null) throw _HandlerError('Library item not found.');

    await _cleanupPlaybackArtifacts(
        await library.playbackArtifactVideosFor(target));
    await library.deleteLibraryItem(target.path);

    _emitActivity(UploadStatus.idle, 'Deleted ${target.name}');
    await onLibraryChanged?.call();

    return _json({
      'ok': true,
      ...await _libraryListing(currentPath.isEmpty ? null : currentPath),
    });
  }

  Future<Response> _handleRename(Request request) async {
    final body = await _readJsonBody(request);
    final relativePath = _readString(body['relativePath'], 'relativePath');
    final entryType = _readEntryType(body['entryType']);
    final currentPath = VideoLibrary.normalizeLibraryDirectoryPath(
        _readOptionalString(body['currentPath']));
    final name = _readString(body['name'], 'name');

    final target = await library.getLibraryItem(relativePath, entryType);
    if (target == null) throw _HandlerError('Library item not found.');

    final videosToCleanup = await library.playbackArtifactVideosFor(target);
    final renamed =
        await library.renameLibraryItem(target.relativePath, entryType, name);

    if (renamed.path != target.path) {
      await _cleanupPlaybackArtifacts(videosToCleanup);
    }

    _emitActivity(
        UploadStatus.idle, 'Renamed ${target.name} to ${renamed.name}');
    await onLibraryChanged?.call();

    return _json({
      'ok': true,
      'item': renamed.toServerJson(),
      ...await _libraryListing(currentPath.isEmpty ? null : currentPath),
    });
  }

  Future<Response> _handleMove(Request request) async {
    final body = await _readJsonBody(request);
    final currentPath = VideoLibrary.normalizeLibraryDirectoryPath(
        _readOptionalString(body['currentPath']));
    final destinationPath = VideoLibrary.normalizeLibraryDirectoryPath(
        _readOptionalString(body['destinationPath']));
    final rawItems = body['items'];
    final items = rawItems is List ? rawItems : const [];

    if (items.isEmpty) {
      throw _HandlerError('Select at least one item to move.');
    }

    var movedCount = 0;
    for (final rawItem in items) {
      if (rawItem is! Map<String, Object?>) {
        throw _HandlerError('Invalid item to move.');
      }
      final relativePath =
          _readString(rawItem['relativePath'], 'relativePath');
      final entryType = _readEntryType(rawItem['entryType']);
      final target = await library.getLibraryItem(relativePath, entryType);
      if (target == null) throw _HandlerError('Library item not found.');

      final videosToCleanup = await library.playbackArtifactVideosFor(target);
      final moved = await library.moveLibraryItem(target.relativePath,
          entryType, destinationPath.isEmpty ? null : destinationPath);

      if (moved.path != target.path) {
        await _cleanupPlaybackArtifacts(videosToCleanup);
        movedCount += 1;
      }
    }

    _emitActivity(UploadStatus.idle,
        'Moved $movedCount item${movedCount == 1 ? '' : 's'}');
    await onLibraryChanged?.call();

    return _json({
      'ok': true,
      'movedCount': movedCount,
      ...await _libraryListing(currentPath.isEmpty ? null : currentPath),
    });
  }
}
