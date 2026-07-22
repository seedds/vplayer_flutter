enum LibraryItemKind { folder, video, subtitle, file }

class LibraryItem {
  const LibraryItem({
    required this.kind,
    required this.name,
    required this.path,
    required this.modified,
    required this.parentPath,
    required this.relativePath,
    this.size = 0,
    this.extension = '',
  });

  final LibraryItemKind kind;
  final String name;

  /// Absolute filesystem path.
  final String path;

  /// Milliseconds since epoch.
  final int modified;

  /// Relative parent path inside the library, or null at root.
  final String? parentPath;

  /// Relative path inside the library (no leading slash).
  final String relativePath;

  final int size;
  final String extension;

  String get id => path;
  bool get isFolder => kind == LibraryItemKind.folder;
  bool get isVideo => kind == LibraryItemKind.video;
  bool get isSubtitle => kind == LibraryItemKind.subtitle;

  Map<String, Object?> toServerJson() => {
        'kind': kind.name,
        'name': name,
        'modified': modified,
        'parentPath': parentPath,
        'relativePath': relativePath,
        if (!isFolder) 'extension': extension,
        if (!isFolder) 'size': size,
      };
}
