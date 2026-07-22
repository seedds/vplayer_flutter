import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/library_item.dart';

const allowedVideoExtensions = ['.mp4', '.mov', '.m4v', '.webm', '.mkv'];
const allowedSubtitleExtensions = ['.srt'];

/// Filesystem layer for the media library.
///
/// All relative paths use `/` separators and never start with a slash.
/// Mirrors the sanitization and layout rules of the original VPlayer app:
/// - `<documents>/videos/` holds media, subtitles, and folders
/// - `<documents>/uploads-tmp/` holds in-progress upload temp files
class VideoLibrary {
  VideoLibrary(this.documentsPath);

  /// Absolute path of the app documents directory.
  final String documentsPath;

  String get videoDirectory => p.join(documentsPath, 'videos');
  String get tempUploadDirectory => p.join(documentsPath, 'uploads-tmp');

  Future<void> ensureAppDirectories() async {
    await Directory(videoDirectory).create(recursive: true);
    await Directory(tempUploadDirectory).create(recursive: true);
  }

  Future<void> clearTempUploads() async {
    await ensureAppDirectories();
    final dir = Directory(tempUploadDirectory);
    await for (final entry in dir.list()) {
      try {
        await entry.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ---- naming rules -------------------------------------------------------

  static String getFileExtension(String fileName) {
    final match = RegExp(r'\.[^.]+$').firstMatch(fileName.toLowerCase());
    return match?.group(0) ?? '';
  }

  static String getFileBaseName(String fileName) =>
      fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');

  static bool isAllowedVideoFileName(String fileName) =>
      allowedVideoExtensions.contains(getFileExtension(fileName));

  static bool isAllowedSubtitleFileName(String fileName) =>
      allowedSubtitleExtensions.contains(getFileExtension(fileName));

  static String sanitizeFolderName(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final normalized = cleaned
        .replaceAll(RegExp(r'^\.+$'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    return normalized.isEmpty ? 'folder' : normalized;
  }

  static String sanitizeFileName(String input) {
    final leaf = input.split(RegExp(r'[\\/]')).last.trim();
    final leafName = leaf.isEmpty ? 'upload' : leaf;
    final cleaned = leafName
        .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    final extension = getFileExtension(cleaned);
    final rawBaseName = extension.isNotEmpty
        ? cleaned.substring(0, cleaned.length - extension.length)
        : cleaned;
    var baseName = rawBaseName
        .replaceAll(RegExp(r'^\.+$'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    if (baseName.isEmpty) baseName = 'upload';
    return '$baseName${extension.toLowerCase()}';
  }

  static List<String> _splitRelativePath(String? input) => (input ?? '')
      .split(RegExp(r'[\\/]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static String _joinRelativePath(String? parentPath, String name) =>
      parentPath == null || parentPath.isEmpty ? name : '$parentPath/$name';

  static String _relativeName(String relativePath) {
    final segments = _splitRelativePath(relativePath);
    return segments.isEmpty ? '' : segments.last;
  }

  static String? _relativeParentPath(String relativePath) {
    final segments = _splitRelativePath(relativePath);
    if (segments.length <= 1) return null;
    return segments.sublist(0, segments.length - 1).join('/');
  }

  /// Sanitizes every segment of a directory path. Returns '' for root.
  static String normalizeLibraryDirectoryPath(String? input) =>
      _splitRelativePath(input).map(sanitizeFolderName).join('/');

  /// Sanitizes a full relative file path (folders + leaf file name).
  static String normalizeLibraryFilePath(String input) {
    final segments = _splitRelativePath(input);
    if (segments.isEmpty) return sanitizeFileName('upload');
    return [
      ...segments.sublist(0, segments.length - 1).map(sanitizeFolderName),
      sanitizeFileName(segments.last),
    ].join('/');
  }

  // ---- path resolution ----------------------------------------------------

  String directoryPathFor(String? relativePath) {
    final normalized = normalizeLibraryDirectoryPath(relativePath);
    return normalized.isEmpty
        ? videoDirectory
        : p.join(videoDirectory, p.joinAll(normalized.split('/')));
  }

  String itemPathFor(String relativePath) =>
      p.join(videoDirectory, p.joinAll(relativePath.split('/')));

  // ---- listing ------------------------------------------------------------

  static int compareLibraryItems(LibraryItem left, LibraryItem right) {
    if (left.isFolder && !right.isFolder) return -1;
    if (!left.isFolder && right.isFolder) return 1;
    return compareNatural(left.name, right.name);
  }

  /// Case-insensitive, numeric-aware comparison (mirrors localeCompare with
  /// {numeric: true, sensitivity: 'base'}).
  static int compareNatural(String a, String b) {
    final ra = _naturalChunks(a.toLowerCase());
    final rb = _naturalChunks(b.toLowerCase());
    final len = ra.length < rb.length ? ra.length : rb.length;
    for (var i = 0; i < len; i++) {
      final ca = ra[i];
      final cb = rb[i];
      final na = int.tryParse(ca);
      final nb = int.tryParse(cb);
      int cmp;
      if (na != null && nb != null) {
        cmp = na.compareTo(nb);
      } else {
        cmp = ca.compareTo(cb);
      }
      if (cmp != 0) return cmp;
    }
    return ra.length.compareTo(rb.length);
  }

  static List<String> _naturalChunks(String input) =>
      RegExp(r'\d+|\D+').allMatches(input).map((m) => m.group(0)!).toList();

  Future<LibraryItem?> buildLibraryItem(String relativePath) async {
    final path = itemPathFor(relativePath);
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return null;

    final name = _relativeName(relativePath);
    final parentPath = _relativeParentPath(relativePath);

    if (type == FileSystemEntityType.directory) {
      final stat = await Directory(path).stat();
      return LibraryItem(
        kind: LibraryItemKind.folder,
        name: name,
        path: path,
        modified: stat.modified.millisecondsSinceEpoch,
        parentPath: parentPath,
        relativePath: relativePath,
      );
    }

    final stat = await File(path).stat();
    final kind = isAllowedSubtitleFileName(name)
        ? LibraryItemKind.subtitle
        : isAllowedVideoFileName(name)
            ? LibraryItemKind.video
            : LibraryItemKind.file;
    return LibraryItem(
      kind: kind,
      name: name,
      path: path,
      size: stat.size,
      modified: stat.modified.millisecondsSinceEpoch,
      extension: getFileExtension(name),
      parentPath: parentPath,
      relativePath: relativePath,
    );
  }

  Future<List<LibraryItem>> listLibraryItems([String? parentPath]) async {
    await ensureAppDirectories();
    final normalizedParent = normalizeLibraryDirectoryPath(parentPath);
    final dir = Directory(directoryPathFor(normalizedParent));
    if (!await dir.exists()) return [];

    final items = <LibraryItem>[];
    await for (final entry in dir.list(followLinks: false)) {
      final entryName = p.basename(entry.path);
      final item = await buildLibraryItem(
        _joinRelativePath(normalizedParent.isEmpty ? null : normalizedParent,
            entryName),
      );
      if (item != null) items.add(item);
    }
    items.sort(compareLibraryItems);
    return items;
  }

  Future<List<LibraryItem>> listAllVideoItems([String? parentPath]) async {
    final normalized = normalizeLibraryDirectoryPath(parentPath);
    final pending = <String?>[normalized.isEmpty ? null : normalized];
    final videos = <LibraryItem>[];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      final items = await listLibraryItems(next);
      for (final item in items) {
        if (item.isFolder) {
          pending.add(item.relativePath);
        } else if (item.isVideo) {
          videos.add(item);
        }
      }
    }
    videos.sort((a, b) => compareNatural(a.relativePath, b.relativePath));
    return videos;
  }

  Future<LibraryItem?> getLibraryItem(
      String relativePath, String entryType) async {
    final normalizedPath = entryType == 'folder'
        ? normalizeLibraryDirectoryPath(relativePath)
        : normalizeLibraryFilePath(relativePath);
    if (normalizedPath.isEmpty) return null;
    return buildLibraryItem(normalizedPath);
  }

  // ---- mutations ----------------------------------------------------------

  Future<({
    String fileName,
    String finalPath,
    String? parentPath,
    String relativePath,
    String tempPath,
  })> createUploadTarget(String relativePath) async {
    await ensureAppDirectories();
    final normalizedPath = normalizeLibraryFilePath(relativePath);
    final parentPath = _relativeParentPath(normalizedPath);
    final sanitizedName = _relativeName(normalizedPath);

    if (parentPath != null) {
      await Directory(directoryPathFor(parentPath)).create(recursive: true);
    }

    final uploadKey =
        '${DateTime.now().millisecondsSinceEpoch}-${_randomSuffix()}';
    return (
      fileName: sanitizedName,
      finalPath: itemPathFor(normalizedPath),
      parentPath: parentPath,
      relativePath: normalizedPath,
      tempPath: p.join(tempUploadDirectory, '$uploadKey.upload'),
    );
  }

  static String _randomSuffix() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final seed = DateTime.now().microsecondsSinceEpoch;
    final buffer = StringBuffer();
    var value = seed;
    for (var i = 0; i < 6; i++) {
      buffer.write(chars[value % chars.length]);
      value = (value ~/ chars.length) ^ (value * 31 + i);
      if (value < 0) value = -value;
    }
    return buffer.toString();
  }

  Future<LibraryItem> createLibraryFolder(
      String? parentPath, String name) async {
    await ensureAppDirectories();
    final normalizedParent = normalizeLibraryDirectoryPath(parentPath);
    final folderName = sanitizeFolderName(name);
    final relativePath = _joinRelativePath(
        normalizedParent.isEmpty ? null : normalizedParent, folderName);
    final path = itemPathFor(relativePath);

    if (await FileSystemEntity.type(path) != FileSystemEntityType.notFound) {
      throw Exception('A file or folder with that name already exists.');
    }
    await Directory(path).create(recursive: true);
    final folder = await buildLibraryItem(relativePath);
    if (folder == null || !folder.isFolder) {
      throw Exception('Could not create the folder.');
    }
    return folder;
  }

  Future<LibraryItem> renameLibraryItem(
      String relativePath, String entryType, String newName) async {
    await ensureAppDirectories();
    final target = await getLibraryItem(relativePath, entryType);
    if (target == null) throw Exception('Library item not found.');

    final sanitizedName = entryType == 'folder'
        ? sanitizeFolderName(newName)
        : sanitizeFileName(newName);
    final nextRelativePath =
        _joinRelativePath(target.parentPath, sanitizedName);
    if (nextRelativePath == target.relativePath) return target;

    final nextPath = itemPathFor(nextRelativePath);
    if (await FileSystemEntity.type(nextPath) !=
        FileSystemEntityType.notFound) {
      throw Exception('A file or folder with that name already exists.');
    }

    if (target.isFolder) {
      await Directory(target.path).rename(nextPath);
    } else {
      await File(target.path).rename(nextPath);
    }
    final renamed = await buildLibraryItem(nextRelativePath);
    if (renamed == null) throw Exception('Could not rename the item.');
    return renamed;
  }

  Future<LibraryItem> moveLibraryItem(String relativePath, String entryType,
      String? destinationParentPath) async {
    await ensureAppDirectories();
    final target = await getLibraryItem(relativePath, entryType);
    if (target == null) throw Exception('Library item not found.');

    final destinationParent =
        normalizeLibraryDirectoryPath(destinationParentPath);
    final destParentOrNull =
        destinationParent.isEmpty ? null : destinationParent;
    if (target.parentPath == destParentOrNull) return target;

    if (target.isFolder) {
      if (destinationParent == target.relativePath ||
          destinationParent.startsWith('${target.relativePath}/')) {
        throw Exception('A folder cannot be moved into itself.');
      }
    }

    final destinationDirectory =
        Directory(directoryPathFor(destParentOrNull));
    if (!await destinationDirectory.exists()) {
      throw Exception('Destination folder not found.');
    }

    final nextRelativePath =
        _joinRelativePath(destParentOrNull, target.name);
    final nextPath = itemPathFor(nextRelativePath);
    if (await FileSystemEntity.type(nextPath) !=
        FileSystemEntityType.notFound) {
      throw Exception(
          'A file or folder with that name already exists in the destination.');
    }

    if (target.isFolder) {
      await Directory(target.path).rename(nextPath);
    } else {
      await File(target.path).rename(nextPath);
    }
    final moved = await buildLibraryItem(nextRelativePath);
    if (moved == null) throw Exception('Could not move the item.');
    return moved;
  }

  Future<void> deleteLibraryItem(String path) async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await File(path).delete();
      }
    } catch (_) {}
  }

  Future<String?> findMatchingSubtitlePath(LibraryItem video) async {
    await ensureAppDirectories();
    final baseName = getFileBaseName(video.name).toLowerCase();
    final siblings = await listLibraryItems(video.parentPath);
    for (final item in siblings) {
      if (item.isSubtitle &&
          getFileBaseName(item.name).toLowerCase() == baseName) {
        return item.path;
      }
    }
    return null;
  }
}
