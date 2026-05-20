import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'dart:io';
import 'dart:convert';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MusicVaultApp());
}

// ============================================================================
// APP ROOT CONFIGURATION
// ============================================================================
class MusicVaultApp extends StatelessWidget {
  const MusicVaultApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Vault',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          brightness: Brightness.dark,
          seedColor: Colors.purple[900]!,
        ),
        scaffoldBackgroundColor: Colors.grey[950],
      ),
      home: const MusicPlayerScreen(),
    );
  }
}

// ============================================================================
// DATA MODELS
// ============================================================================
class MusicTrack {
  final String id;
  final String name;
  final String path;
  final String albumName;
  final Duration? duration;

  MusicTrack({
    required this.id,
    required this.name,
    required this.path,
    required this.albumName,
    this.duration,
  });

  String get displayName => name.replaceAll(RegExp(r'\.[^/.]+$'), '');

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'albumName': albumName,
  };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    id: json['id'],
    name: json['name'],
    path: json['path'],
    albumName: json['albumName'],
  );
}

class AlbumInfo {
  final String name;
  final List<MusicTrack> tracks;
  final int trackCount;

  AlbumInfo({
    required this.name,
    required this.tracks,
  }) : trackCount = tracks.length;
}

// ============================================================================
// PERSISTENT STORAGE LAYER
// ============================================================================
class MusicLibrary {
  static const String _tracksKey = 'music_vault_tracks';
  static const String _albumsKey = 'music_vault_albums';
  final SharedPreferences prefs;

  MusicLibrary(this.prefs);

  // Get all tracks
  Future<List<MusicTrack>> getTracks() async {
    final stored = prefs.getStringList(_tracksKey) ?? [];
    return stored.map((json) => MusicTrack.fromJson(jsonDecode(json))).toList();
  }

  // Get organized albums
  Future<Map<String, List<MusicTrack>>> getAlbums() async {
    final tracks = await getTracks();
    final albums = <String, List<MusicTrack>>{};
    for (var track in tracks) {
      albums.putIfAbsent(track.albumName, () => []).add(track);
    }
    return albums;
  }

  // Add single track
  Future<void> addTrack(MusicTrack track) async {
    final tracks = await getTracks();
    tracks.add(track);
    await _saveTracks(tracks);
  }

  // Delete track by ID
  Future<void> deleteTrack(String trackId) async {
    final tracks = await getTracks();
    tracks.removeWhere((t) => t.id == trackId);
    await _saveTracks(tracks);
  }

  // Move track to album (reorganize)
  Future<void> moveTrackToAlbum(String trackId, String newAlbum) async {
    final tracks = await getTracks();
    final trackIndex = tracks.indexWhere((t) => t.id == trackId);
    if (trackIndex != -1) {
      final oldTrack = tracks[trackIndex];
      tracks[trackIndex] = MusicTrack(
        id: oldTrack.id,
        name: oldTrack.name,
        path: oldTrack.path,
        albumName: newAlbum,
      );
      await _saveTracks(tracks);
    }
  }

  // Save all tracks
  Future<void> _saveTracks(List<MusicTrack> tracks) async {
    final json = tracks.map((t) => jsonEncode(t.toJson())).toList();
    await prefs.setStringList(_tracksKey, json);
  }

  // Clear library
  Future<void> clearAllTracks() async {
    await prefs.remove(_tracksKey);
    await prefs.remove(_albumsKey);
  }
}

// ============================================================================
// MAIN PLAYER SCREEN
// ============================================================================

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({Key? key}) : super(key: key);

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen>
    with TickerProviderStateMixin {
  // Audio & Playback State
  late AudioPlayer _audioPlayer;
  late MusicLibrary _library;
  List<MusicTrack> _allTracks = [];
  Map<String, List<MusicTrack>> _albums = {};
  int _currentTrackIndex = 0;
  bool _isPlaying = false;
  bool _isShuffleEnabled = false;
  LoopMode _repeatMode = LoopMode.off;

  // UI State
  bool _isPlayerExpanded = false;
  int _viewMode = 0; // 0 = All Music, 1 = Albums Grid
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _expandController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _expandAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _expandController, curve: Curves.easeOutCubic),
    );
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final prefs = await SharedPreferences.getInstance();
    _library = MusicLibrary(prefs);

    // Configure audio for background playback
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setLoopMode(LoopMode.off);
    } catch (e) {
      debugPrint('Audio config error: $e');
    }

    // Listen to playback state changes
    _audioPlayer.playingStream.listen((playing) {
      setState(() => _isPlaying = playing);
    });

    // Listen to track index changes (auto-next)
    _audioPlayer.currentIndexStream.listen((index) {
      if (index != null && index != _currentTrackIndex) {
        setState(() => _currentTrackIndex = index);
      }
    });

    // Load library on startup
    await _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    try {
      final tracks = await _library.getTracks();
      final albums = await _library.getAlbums();
      setState(() {
        _allTracks = tracks;
        _albums = albums;
      });
      if (tracks.isNotEmpty) {
        await _setupAudioQueue();
      }
    } catch (e) {
      debugPrint('Load library error: $e');
    }
  }

  Future<void> _setupAudioQueue() async {
    if (_allTracks.isEmpty) return;
    try {
      final sources = _allTracks
          .map((track) => AudioSource.file(track.path))
          .toList();
      await _audioPlayer.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: _currentTrackIndex,
      );
    } catch (e) {
      debugPrint('Queue setup error: $e');
    }
  }

  Future<void> _importMusicFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      final appDocDir = await getApplicationDocumentsDirectory();
      final musicDir = Directory('${appDocDir.path}/Music');
      if (!await musicDir.exists()) {
        await musicDir.create(recursive: true);
      }

      for (var file in result.files) {
        if (file.path == null) continue;

        try {
          final sourceFile = File(file.path!);
          final fileName = sourceFile.path.split('/').last;
          final destinationPath = '${musicDir.path}/$fileName';

          // Copy to app sandbox
          if (await sourceFile.exists()) {
            await sourceFile.copy(destinationPath);

            final albumName = _extractAlbumName(file.path!);
            final track = MusicTrack(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: fileName,
              path: destinationPath,
              albumName: albumName,
            );

            await _library.addTrack(track);
          }
        } catch (e) {
          debugPrint('File import error for ${file.path}: $e');
        }
      }

      await _loadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tracks imported successfully')),
        );
      }
    } catch (e) {
      _showErrorDialog('Import failed: $e');
    }
  }

  String _extractAlbumName(String path) {
    final parts = path.split('/');
    if (parts.length > 1) {
      return parts[parts.length - 2];
    }
    return 'Unknown Album';
  }

  Future<void> _playTrack(int index) async {
    try {
      await _audioPlayer.seek(Duration.zero, index: index);
      await _audioPlayer.play();
      setState(() => _currentTrackIndex = index);
    } catch (e) {
      _showErrorDialog('Cannot play track: $e');
    }
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_audioPlayer.playing) {
        await _audioPlayer.pause();
      } else {
        if (_allTracks.isEmpty) {
          _showErrorDialog('No tracks available');
          return;
        }
        await _audioPlayer.play();
      }
    } catch (e) {
      _showErrorDialog('Playback error: $e');
    }
  }

  Future<void> _skipNext() async {
    if (_currentTrackIndex < _allTracks.length - 1) {
      await _playTrack(_currentTrackIndex + 1);
    }
  }

  Future<void> _skipPrevious() async {
    if (_currentTrackIndex > 0) {
      await _playTrack(_currentTrackIndex - 1);
    }
  }

  Future<void> _toggleShuffle() async {
    setState(() => _isShuffleEnabled = !_isShuffleEnabled);
  }

  Future<void> _toggleRepeat() async {
    setState(() {
      _repeatMode = _repeatMode == LoopMode.off
          ? LoopMode.one
          : _repeatMode == LoopMode.one
              ? LoopMode.all
              : LoopMode.off;
      _audioPlayer.setLoopMode(_repeatMode);
    });
  }

  Future<void> _deleteTrack(String trackId) async {
    await _library.deleteTrack(trackId);
    await _loadLibrary();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Track deleted')),
      );
    }
  }

  void _showTrackMenu(BuildContext context, MusicTrack track, int index) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.displayName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.albumName,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play'),
              onTap: () {
                Navigator.pop(context);
                _playTrack(index);
              },
            ),
            ListTile(
              leading: const Icon(Icons.skip_next_rounded),
              title: const Text('Play Next'),
              onTap: () {
                Navigator.pop(context);
                // Implement play next logic
                _showInfoSnackBar('Play Next: ${track.displayName}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: const Text('Move to Album'),
              onTap: () {
                Navigator.pop(context);
                _showAlbumSelector(track);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _deleteTrack(track.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAlbumSelector(MusicTrack track) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Album'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _albums.keys.map((albumName) {
              return ListTile(
                title: Text(albumName),
                onTap: () {
                  Navigator.pop(context);
                  _library.moveTrackToAlbum(track.id, albumName);
                  _loadLibrary();
                },
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showInfoSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          _buildMainContent(),
          if (_allTracks.isNotEmpty) _buildPlayerOverlay(),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (_allTracks.isEmpty) {
      return _buildEmptyState();
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // Top Bar with Navigation
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            color: Colors.grey[950],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Music Vault',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w300,
                    letterSpacing: 1.0,
                  ),
                ),
                Row(
                  children: [
                    GestureDetector(
                      onTap: () => setState(() => _viewMode = 0),
                      child: Opacity(
                        opacity: _viewMode == 0 ? 1.0 : 0.5,
                        child: const Icon(Icons.list_rounded),
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: () => setState(() => _viewMode = 1),
                      child: Opacity(
                        opacity: _viewMode == 1 ? 1.0 : 0.5,
                        child: const Icon(Icons.grid_3x3_rounded),
                      ),
                    ),
                    const SizedBox(width: 16),
                    GestureDetector(
                      onTap: _importMusicFiles,
                      child: const Icon(Icons.add_circle_outline_rounded),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Content Area
          Expanded(
            child: _viewMode == 0
                ? _buildAllMusicList()
                : _buildAlbumsGrid(),
          ),
        ],
      ),
    );
  }

  Widget _buildAllMusicList() {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 140),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_allTracks.length} Tracks',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey[400],
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          ..._allTracks.asMap().entries.map((entry) {
            final index = entry.key;
            final track = entry.value;
            final isPlaying = _isPlaying && _currentTrackIndex == index;

            return GestureDetector(
              onTap: () => _playTrack(index),
              onLongPress: () => _showTrackMenu(context, track, index),
              child: Container(
                color: isPlaying ? Colors.purple[900]?.withOpacity(0.2) : null,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 24,
                      color: isPlaying ? Colors.purple[300] : Colors.grey[600],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
                              color: isPlaying ? Colors.purple[300] : Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            track.albumName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      color: Colors.grey[900],
                      onSelected: (value) {
                        if (value == 'play') {
                          _playTrack(index);
                        } else if (value == 'delete') {
                          _deleteTrack(track.id);
                        } else if (value == 'move') {
                          _showAlbumSelector(track);
                        }
                      },
                      itemBuilder: (BuildContext context) => [
                        const PopupMenuItem(
                          value: 'play',
                          child: Row(
                            children: [
                              Icon(Icons.play_arrow_rounded, size: 18),
                              SizedBox(width: 8),
                              Text('Play'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'move',
                          child: Row(
                            children: [
                              Icon(Icons.folder_rounded, size: 18),
                              SizedBox(width: 8),
                              Text('Move'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_rounded, size: 18, color: Colors.red),
                              SizedBox(width: 8),
                              Text('Delete', style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ],
                      child: Icon(Icons.more_vert_rounded, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  Widget _buildAlbumsGrid() {
    final albumsList = _albums.entries.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 140),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              '${albumsList.length} Albums',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey[400],
                letterSpacing: 0.5,
              ),
            ),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.0,
            ),
            itemCount: albumsList.length,
            itemBuilder: (context, index) {
              final entry = albumsList[index];
              final albumName = entry.key;
              final tracks = entry.value;

              return GestureDetector(
                onTap: () {
                  setState(() => _viewMode = 0);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.grey[800]!,
                      width: 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.purple[900]!.withOpacity(0.2),
                              Colors.purple[800]!.withOpacity(0.1),
                            ],
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.album_rounded,
                            size: 48,
                            color: Colors.purple[400]?.withOpacity(0.6),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(12),
                              bottomRight: Radius.circular(12),
                            ),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0),
                                Colors.black.withOpacity(0.8),
                              ],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                albumName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${tracks.length} track${tracks.length != 1 ? 's' : ''}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_note_rounded,
              size: 80,
              color: Colors.grey[800],
            ),
            const SizedBox(height: 24),
            Text(
              'Music Vault',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w300,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Premium Offline Music Player',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: _importMusicFiles,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Import Music'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 36,
                  vertical: 14,
                ),
                backgroundColor: Colors.purple[900],
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayerOverlay() {
    return DraggableScrollableSheet(
      initialChildSize: 0.12,
      minChildSize: 0.12,
      maxChildSize: 1.0,
      snap: true,
      snapSizes: [0.12, 1.0],
      builder: (context, scrollController) {
        return AnimatedBuilder(
          animation: _expandAnimation,
          builder: (context, child) {
            final expanded = _expandAnimation.value > 0.5;

            return Container(
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(28 * (1 - _expandAnimation.value)),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 20 + (_expandAnimation.value * 10),
                    offset: Offset(0, -10 + (_expandAnimation.value * 5)),
                  ),
                ],
              ),
              child: expanded
                  ? _buildExpandedPlayerView(scrollController)
                  : _buildMiniPlayerView(),
            );
          },
        );
      },
      onDragged: (extent) {
        if (extent > 0.5) {
          if (!_isPlayerExpanded) {
            setState(() => _isPlayerExpanded = true);
            _expandController.forward();
          }
        } else {
          if (_isPlayerExpanded) {
            setState(() => _isPlayerExpanded = false);
            _expandController.reverse();
          }
        }
      },
    );
  }

  Widget _buildMiniPlayerView() {
    if (_allTracks.isEmpty) return const SizedBox.shrink();

    final track = _allTracks[_currentTrackIndex];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  track.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  track.albumName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _togglePlayPause,
            icon: Icon(
              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 28,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedPlayerView(ScrollController scrollController) {
    if (_allTracks.isEmpty) return const SizedBox.shrink();

    final track = _allTracks[_currentTrackIndex];

    return ListView(
      controller: scrollController,
      children: [
        // Drag Handle
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        // Main Player Content
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 32),

              // Artwork Container with Animation
              ScaleTransition(
                scale: Tween<double>(begin: 0.9, end: 1.0).animate(
                  CurvedAnimation(parent: _expandController, curve: Curves.elasticOut),
                ),
                child: Container(
                  width: 280,
                  height: 280,
                  decoration: BoxDecoration(
                    color: Colors.purple[900]?.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.purple[700]!.withOpacity(0.4),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.purple[900]!.withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.music_note_rounded,
                    size: 120,
                    color: Colors.purple[400],
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // Track Info
              Text(
                track.displayName,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                track.albumName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
                  letterSpacing: 0.2,
                ),
              ),

              const SizedBox(height: 40),

              // Progress Bar Section
              StreamBuilder<Duration>(
                stream: _audioPlayer.positionStream,
                builder: (context, posSnapshot) {
                  final position = posSnapshot.data ?? Duration.zero;
                  final duration = _audioPlayer.duration ?? Duration.zero;

                  return Column(
                    children: [
                      AudioVideoProgressBar(
                        onSeek: (duration) {
                          _audioPlayer.seek(duration);
                        },
                        duration: duration,
                        progress: position,
                        buffered: Duration.zero,
                        barHeight: 5,
                        handleRadius: 7,
                        thumbColor: Colors.purple[400]!,
                        baseBarColor: Colors.grey[800]!,
                        progressBarColor: Colors.purple[500]!,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatDuration(position),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            _formatDuration(duration),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 40),

              // Control Buttons Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Shuffle Button
                  GestureDetector(
                    onTap: _toggleShuffle,
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isShuffleEnabled
                            ? Colors.purple[800]?.withOpacity(0.5)
                            : Colors.grey[800]?.withOpacity(0.3),
                      ),
                      child: Icon(
                        Icons.shuffle_rounded,
                        color: _isShuffleEnabled
                            ? Colors.purple[300]
                            : Colors.grey[600],
                        size: 22,
                      ),
                    ),
                  ),

                  // Skip Previous
                  GestureDetector(
                    onTap: _skipPrevious,
                    child: Icon(
                      Icons.skip_previous_rounded,
                      size: 36,
                      color: _currentTrackIndex > 0
                          ? Colors.white
                          : Colors.grey[700],
                    ),
                  ),

                  // Play/Pause (Large)
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.purple[900]!,
                          Colors.purple[700]!,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.purple[900]!.withOpacity(0.4),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: IconButton(
                      onPressed: _togglePlayPause,
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 44,
                        color: Colors.white,
                      ),
                    ),
                  ),

                  // Skip Next
                  GestureDetector(
                    onTap: _skipNext,
                    child: Icon(
                      Icons.skip_next_rounded,
                      size: 36,
                      color: _currentTrackIndex < _allTracks.length - 1
                          ? Colors.white
                          : Colors.grey[700],
                    ),
                  ),

                  // Repeat Button
                  GestureDetector(
                    onTap: _toggleRepeat,
                    child: Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _repeatMode != LoopMode.off
                            ? Colors.purple[800]?.withOpacity(0.5)
                            : Colors.grey[800]?.withOpacity(0.3),
                      ),
                      child: Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Icon(
                              Icons.repeat_rounded,
                              color: _repeatMode != LoopMode.off
                                  ? Colors.purple[300]
                                  : Colors.grey[600],
                              size: 22,
                            ),
                            if (_repeatMode == LoopMode.one)
                              Positioned(
                                bottom: 6,
                                right: 5,
                                child: Container(
                                  width: 16,
                                  height: 16,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.purple[400],
                                  ),
                                  child: const Center(
                                    child: Text(
                                      '1',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 40),

              // Add More Tracks Button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: _importMusicFiles,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add More Tracks'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple[900],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _expandController.dispose();
    super.dispose();
  }
}
