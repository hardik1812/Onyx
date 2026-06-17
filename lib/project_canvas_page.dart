import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:fastreminder/src/rust/api/schema.dart';
import 'package:fastreminder/src/rust/api/simple.dart';
import 'package:fastreminder/src/rust/api/classifiers.dart';

const Map<String, IconData> _projectFolderIcons = {
  'General': Icons.inbox_rounded,
  'UI/UX': Icons.palette_rounded,
  'Backend': Icons.dns_rounded,
  'Database': Icons.storage_rounded,
  'Icebox': Icons.ac_unit_rounded,
  'Testing': Icons.bug_report_rounded,
  'DevOps': Icons.cloud_queue_rounded,
};

// Material You tonal palette — Pixel-grade pastels
const List<Color> _accentColors = [
  Color(0xFFA8C7FA), // Blue
  Color(0xFFC4E7C4), // Green
  Color(0xFFFAD8C2), // Peach
  Color(0xFFE8DEF8), // Purple
  Color(0xFFF2B8B5), // Rose
  Color(0xFFB2EBF2), // Teal
  Color(0xFFFFF3B0), // Amber
  Color(0xFFD7CCC8), // Warm Grey
];

// Dark surface hierarchy — Pixel dark theme
const Color _surfaceBase = Color(0xFF0E0E12);
const Color _surfaceCard = Color(0xFF1A1A22);
const Color _textPrimary = Color(0xFFE6E1E5);
const Color _accentBlue = Color(0xFFA8C7FA);

class ProjectItem {
  String text;
  bool done;
  String? photoPath;

  ProjectItem({
    required this.text,
    this.done = false,
    this.photoPath,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'done': done,
        'photoPath': photoPath,
      };

  factory ProjectItem.fromJson(Map<String, dynamic> json) {
    return ProjectItem(
      text: json['text'] as String? ?? '',
      done: json['done'] as bool? ?? false,
      photoPath: json['photoPath'] as String?,
    );
  }
}

class ProjectData {
  String name;
  Map<String, List<ProjectItem>> folders;

  ProjectData({
    required this.name,
    required this.folders,
  });

  Map<String, dynamic> toJson() => {
        'type': 'project',
        'name': name,
        'folders': folders.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      };

  factory ProjectData.fromJson(Map<String, dynamic> json) {
    final foldersMap = <String, List<ProjectItem>>{};
    final rawFolders = json['folders'] as Map<String, dynamic>?;
    if (rawFolders != null) {
      rawFolders.forEach((key, value) {
        if (value is List) {
          foldersMap[key] = value
              .map((e) => ProjectItem.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      });
    }
    // If folders map is empty, initialize default folders
    if (foldersMap.isEmpty) {
      foldersMap['General'] = [];
      foldersMap['UI/UX'] = [];
      foldersMap['Backend'] = [];
      foldersMap['Database'] = [];
      foldersMap['Icebox'] = [];
    }
    return ProjectData(
      name: json['name'] as String? ?? 'Project',
      folders: foldersMap,
    );
  }
}

ProjectData? tryParseProject(String contextText) {
  if (!contextText.trim().startsWith('{') || !contextText.trim().endsWith('}')) {
    return null;
  }
  try {
    final Map<String, dynamic> decoded = json.decode(contextText) as Map<String, dynamic>;
    if (decoded['type'] == 'project') {
      return ProjectData.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}



class ProjectCanvasPage extends StatefulWidget {
  final Reminder reminder;
  final ProjectData initialData;

  const ProjectCanvasPage({
    super.key,
    required this.reminder,
    required this.initialData,
  });

  @override
  State<ProjectCanvasPage> createState() => _ProjectCanvasPageState();
}

class _ProjectCanvasPageState extends State<ProjectCanvasPage> {
  late ProjectData _projectData;
  late TextEditingController _inputController;
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  bool _isSaving = false;
  final Set<String> _expandedFolders = {};
  String? _mentionQuery;
  String? _manuallySelectedFolder;
  final FocusNode _inputFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Deep copy folder map
    final Map<String, List<ProjectItem>> copiedFolders = {};
    widget.initialData.folders.forEach((key, value) {
      copiedFolders[key] = List.from(value);
    });

    _projectData = ProjectData(
      name: widget.initialData.name,
      folders: copiedFolders,
    );
    _inputController = TextEditingController();
    _inputController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _inputController.removeListener(_onTextChanged);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _inputController.text;
    final cursorPosition = _inputController.selection.baseOffset;

    // Check if space was typed and we have a query
    if (cursorPosition > 0 &&
        cursorPosition <= text.length &&
        text[cursorPosition - 1] == ' ') {
      final textBeforeSpace = text.substring(0, cursorPosition - 1);
      final lastWordMatch = RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(textBeforeSpace);
      if (lastWordMatch != null) {
        final query = lastWordMatch.group(1)!;
        final matched = _getMatchedFolders(query);
        if (matched.isNotEmpty) {
          // Auto complete to the first matched suggestion!
          final suggestion = matched.first;
          final replacedText =
              '${textBeforeSpace.substring(0, lastWordMatch.start)}@$suggestion ${text.substring(cursorPosition)}';
          final newOffset = lastWordMatch.start + suggestion.length + 2;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _inputController.value = TextEditingValue(
                text: replacedText,
                selection: TextSelection.collapsed(offset: newOffset),
              );
            }
          });
          setState(() {
            _mentionQuery = null;
          });
          return;
        }
      }
    }

    // Normal typing, find active suggestion query
    if (cursorPosition >= 0 && cursorPosition <= text.length) {
      final textBeforeCursor = text.substring(0, cursorPosition);
      final match = RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(textBeforeCursor);

      setState(() {
        if (match != null) {
          _mentionQuery = match.group(1)!;
        } else {
          _mentionQuery = null;
        }
      });
    } else {
      setState(() {
        _mentionQuery = null;
      });
    }
  }

  List<String> _getMatchedFolders(String query) {
    if (query.isEmpty) {
      return _projectData.folders.keys.toList();
    }
    return _projectData.folders.keys
        .where((f) => f.toLowerCase().startsWith(query.toLowerCase()))
        .toList();
  }

  String _determineTargetFolder(String text) {
    if (_manuallySelectedFolder != null) {
      return _manuallySelectedFolder!;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return 'General';
    }
    if (trimmed.startsWith(':')) {
      final spaceIndex = trimmed.indexOf(' ');
      if (spaceIndex != -1) {
        final prefix = trimmed.substring(1, spaceIndex).trim().toLowerCase();
        String? matchedKey = _prefixAliases[prefix];
        if (matchedKey == null) {
          for (final key in _projectData.folders.keys) {
            if (key.toLowerCase() == prefix) {
              matchedKey = key;
              break;
            }
          }
        }
        if (matchedKey != null) {
          return matchedKey;
        } else {
          final capitalizedPrefix = prefix[0].toUpperCase() + prefix.substring(1);
          return capitalizedPrefix;
        }
      }
    }
    
    // Auto classify intent using the Rust classifier
    final classified = classifyIntent(context: trimmed);
    if (_projectData.folders.containsKey(classified)) {
      return classified;
    }
    return 'General';
  }

  void _applyFolderSuggestionValue(String suggestion) {
    HapticFeedback.lightImpact();
    final text = _inputController.text;
    final cursorPosition = _inputController.selection.baseOffset;
    if (cursorPosition >= 0 && cursorPosition <= text.length) {
      final textBeforeCursor = text.substring(0, cursorPosition);
      final match = RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(textBeforeCursor);
      if (match != null) {
        final replacedText =
            '${textBeforeCursor.substring(0, match.start)}@$suggestion ${text.substring(cursorPosition)}';
        final newOffset = match.start + suggestion.length + 2;

        setState(() {
          _inputController.value = TextEditingValue(
            text: replacedText,
            selection: TextSelection.collapsed(offset: newOffset),
          );
          _mentionQuery = null;
        });
        _inputFocusNode.requestFocus();
      }
    }
  }

  void _saveChanges() {
    if (widget.reminder.id != null) {
      setState(() {
        _isSaving = true;
      });
      updateReminderContext(
        id: widget.reminder.id!,
        context: jsonEncode(_projectData.toJson()),
      );
      // Aesthetic visual feedback transition delay
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() {
            _isSaving = false;
          });
        }
      });
    }
  }

  Color _getFolderColor(String folder) {
    final nameLower = folder.toLowerCase();
    if (nameLower.contains('design') || nameLower.contains('ui') || nameLower.contains('ux') || nameLower.contains('overhaul')) {
      return const Color(0xFFFFD54F); // Yellow/gold
    }
    if (nameLower.contains('roadmap') || nameLower.contains('plan') || nameLower.contains('note') || nameLower.contains('q3')) {
      return const Color(0xFF9E9EA8); // Neutral/grey
    }
    if (nameLower.contains('architecture') || nameLower.contains('backend') || nameLower.contains('database') || nameLower.contains('ideas')) {
      return const Color(0xFFC8B3E8); // Purple/lavender
    }
    final index = folder.hashCode.abs() % _accentColors.length;
    return _accentColors[index];
  }

  IconData _getFolderIcon(String folder) {
    return _projectFolderIcons[folder] ?? Icons.folder_open_rounded;
  }

  void _showAddFolderDialog() {
    final folderNameController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1D1B20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text(
            'Add Folder',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: TextField(
            controller: folderNameController,
            style: const TextStyle(color: Colors.white),
            cursorColor: const Color(0xFFA8C7FA),
            decoration: InputDecoration(
              hintText: 'Folder Name (e.g. Design)',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
              enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFFA8C7FA)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.pop(context);
              },
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                final name = folderNameController.text.trim();
                if (name.isNotEmpty) {
                  setState(() {
                    if (!_projectData.folders.containsKey(name)) {
                      _projectData.folders[name] = [];
                    }
                  });
                  _saveChanges();
                  Navigator.pop(context);
                }
              },
              child: const Text('Add', style: TextStyle(color: Color(0xFFA8C7FA))),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickImageForFolder(String folderName) async {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1D1B20),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt_rounded, color: Colors.white),
                title: const Text('Camera', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  HapticFeedback.lightImpact();
                  Navigator.pop(context);
                  final XFile? image = await _picker.pickImage(source: ImageSource.camera);
                  if (image != null) _saveImageToFolder(folderName, image.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: Colors.white),
                title: const Text('Gallery', style: TextStyle(color: Colors.white)),
                onTap: () async {
                  HapticFeedback.lightImpact();
                  Navigator.pop(context);
                  final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
                  if (image != null) _saveImageToFolder(folderName, image.path);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveImageToFolder(String folderName, String path) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final fileName = p.basename(path);
    final savedFile = await File(path).copy('${appDocDir.path}/$fileName');

    setState(() {
      _projectData.folders[folderName]!.add(
        ProjectItem(text: '', done: false, photoPath: savedFile.path),
      );
    });
    _saveChanges();
  }

  void _confirmDeleteFolder(String folderName, int itemCount) {
    HapticFeedback.mediumImpact();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1D1B20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 22),
              const SizedBox(width: 8),
              const Text(
                'Delete Folder',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
          content: RichText(
            text: TextSpan(
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14, height: 1.5),
              children: [
                const TextSpan(text: 'Are you sure you want to delete '),
                TextSpan(
                  text: folderName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: itemCount > 0
                      ? '?\n\n$itemCount item${itemCount == 1 ? '' : 's'} will be permanently removed.'
                      : '?\n\nThis folder is empty.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.pop(context);
              },
              child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                Navigator.pop(context);
                setState(() {
                  _projectData.folders.remove(folderName);
                  _expandedFolders.remove(folderName);
                });
                _saveChanges();
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  // Shorthand aliases for quick folder routing via :prefix
  static const Map<String, String> _prefixAliases = {
    'ui': 'UI/UX',
    'ux': 'UI/UX',
    'design': 'UI/UX',
    'front': 'UI/UX',
    'frontend': 'UI/UX',
    'be': 'Backend',
    'back': 'Backend',
    'backend': 'Backend',
    'server': 'Backend',
    'api': 'Backend',
    'db': 'Database',
    'data': 'Database',
    'database': 'Database',
    'sql': 'Database',
    'ice': 'Icebox',
    'icebox': 'Icebox',
    'later': 'Icebox',
    'v2': 'Icebox',
    'backlog': 'Icebox',
    'test': 'Testing',
    'testing': 'Testing',
    'qa': 'Testing',
    'bug': 'Testing',
    'ops': 'DevOps',
    'devops': 'DevOps',
    'deploy': 'DevOps',
    'infra': 'DevOps',
    'cloud': 'DevOps',
    'gen': 'General',
    'general': 'General',
    'misc': 'General',
  };

  void _routeCommandInput(String val) {
    final text = val.trim();
    if (text.isEmpty) return;

    String targetQuadrant = 'General';
    String cleanText = text;

    if (_manuallySelectedFolder != null) {
      targetQuadrant = _manuallySelectedFolder!;
      if (text.startsWith(':')) {
        final spaceIndex = text.indexOf(' ');
        if (spaceIndex != -1) {
          cleanText = text.substring(spaceIndex + 1).trim();
        }
      }
    } else if (text.startsWith(':')) {
      final spaceIndex = text.indexOf(' ');
      if (spaceIndex != -1) {
        final prefix = text.substring(1, spaceIndex).trim().toLowerCase();

        // Check shorthand aliases first
        String? matchedKey = _prefixAliases[prefix];

        // If no alias match, check folder names directly (case-insensitive)
        if (matchedKey == null) {
          for (final key in _projectData.folders.keys) {
            if (key.toLowerCase() == prefix) {
              matchedKey = key;
              break;
            }
          }
        }

        if (matchedKey != null) {
          targetQuadrant = matchedKey;
          cleanText = text.substring(spaceIndex + 1).trim();
        } else {
          // Create a new folder dynamically with the prefix name
          final capitalizedPrefix = prefix[0].toUpperCase() + prefix.substring(1);
          targetQuadrant = capitalizedPrefix;
          if (!_projectData.folders.containsKey(targetQuadrant)) {
            _projectData.folders[targetQuadrant] = [];
          }
          cleanText = text.substring(spaceIndex + 1).trim();
        }
      }
    } else {
      // Auto classify intent using the Rust classifier
      final classified = classifyIntent(context: text);
      // Check if the classified result matches a folder we have
      if (_projectData.folders.containsKey(classified)) {
        targetQuadrant = classified;
      } else {
        // Classifier returned a category not in our folders, default to General
        targetQuadrant = 'General';
      }
    }

    if (cleanText.isEmpty) return;

    HapticFeedback.lightImpact();
    setState(() {
      if (!_projectData.folders.containsKey(targetQuadrant)) {
        _projectData.folders[targetQuadrant] = [];
      }
      _projectData.folders[targetQuadrant]!.add(ProjectItem(text: cleanText, done: false));
      if (targetQuadrant != 'General') {
        _expandedFolders.add(targetQuadrant);
      }
      _manuallySelectedFolder = null; // Reset manual lock
    });

    _saveChanges();
    _inputController.clear();
  }

  void _showFullScreenImage(String imagePath) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.zero,
          child: Stack(
            alignment: Alignment.center,
            children: [
              InteractiveViewer(
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              Positioned(
                top: 40,
                right: 20,
                child: CircleAvatar(
                  backgroundColor: Colors.black54,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Navigator.pop(context);
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFolderListCard(String folderName, List<ProjectItem> items) {
    final folderColor = _getFolderColor(folderName);
    final folderIcon = _getFolderIcon(folderName);
    final doneCount = items.where((i) => i.done).length;
    final totalCount = items.where((i) => i.photoPath == null).length;
    final isExpanded = _expandedFolders.contains(folderName);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _surfaceCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isExpanded ? folderColor.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                if (isExpanded) {
                  _expandedFolders.remove(folderName);
                } else {
                  _expandedFolders.add(folderName);
                }
              });
            },
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: folderColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(folderIcon, color: folderColor, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folderName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$totalCount nodes',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: isExpanded
                ? Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (totalCount > 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: totalCount > 0 ? doneCount / totalCount : 0,
                                minHeight: 3,
                                backgroundColor: Colors.white.withValues(alpha: 0.04),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  folderColor.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ),
                        if (items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'No items yet',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.3),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            itemCount: items.length,
                            itemBuilder: (context, index) {
                              final item = items[index];
                              if (item.photoPath != null) {
                                return _buildPhotoItem(folderName, item, index);
                              } else {
                                return _buildCheckItem(folderName, item, index);
                              }
                            },
                          ),
                        Padding(
                          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12, top: 4),
                          child: Row(
                            children: [
                              Text(
                                '$doneCount/$totalCount done',
                                style: TextStyle(
                                  color: folderColor.withValues(alpha: 0.7),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                icon: Icon(Icons.add_photo_alternate_outlined, color: folderColor, size: 16),
                                label: Text('Add Photo', style: TextStyle(color: folderColor, fontSize: 12)),
                                onPressed: () => _pickImageForFolder(folderName),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 16),
                                label: const Text('Delete Folder', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                                onPressed: () => _confirmDeleteFolder(folderName, items.length),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoItem(String folderName, ProjectItem item, int index) {
    final folderColor = _getFolderColor(folderName);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _showFullScreenImage(item.photoPath!);
        },
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 72,
                width: double.infinity,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: folderColor.withValues(alpha: 0.15),
                    width: 1,
                  ),
                ),
                child: Image.file(
                  File(item.photoPath!),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _projectData.folders[folderName]!.removeAt(index);
                  });
                  _saveChanges();
                },
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close_rounded, color: Colors.white70, size: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckItem(String folderName, ProjectItem item, int index) {
    final folderColor = _getFolderColor(folderName);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: Material(
        color: item.done
            ? folderColor.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() {
              item.done = !item.done;
            });
            _saveChanges();
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: item.done ? folderColor : Colors.transparent,
                    border: Border.all(
                      color: item.done
                          ? folderColor
                          : Colors.white.withValues(alpha: 0.2),
                      width: 1.5,
                    ),
                  ),
                  child: item.done
                      ? const Icon(
                          Icons.check_rounded,
                          size: 13,
                          color: _surfaceBase,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.text,
                    style: TextStyle(
                      color: item.done
                          ? Colors.white.withValues(alpha: 0.3)
                          : _textPrimary,
                      fontSize: 14,
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      decorationColor: Colors.white.withValues(alpha: 0.2),
                      height: 1.3,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _projectData.folders[folderName]!.removeAt(index);
                    });
                    _saveChanges();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      color: Colors.white.withValues(alpha: 0.2),
                      size: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _ParsedQueueItem _parseQueueItem(String text, int index) {
    final versionRegex = RegExp(r'\b(v\d+\.\d+(?:\.\d+)?)\b');
    final match = versionRegex.firstMatch(text);
    String cleanText = text;
    String? versionTag;
    if (match != null) {
      versionTag = match.group(1);
      cleanText = text.replaceFirst(versionRegex, '').trim();
      cleanText = cleanText.replaceAll(RegExp(r'\s+'), ' ');
    }

    final String timeAgo;
    if (index == 0) {
      timeAgo = '2h ago';
    } else if (index == 1) {
      timeAgo = 'Yesterday';
    } else {
      timeAgo = '${index + 1}d ago';
    }

    return _ParsedQueueItem(
      cleanText: cleanText,
      versionTag: versionTag,
      timeAgo: timeAgo,
    );
  }

  Widget _buildUnsortedQueueCard(List<ProjectItem> items) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _surfaceCard,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
      ),
      child: items.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
              child: Center(
                child: Text(
                  'Queue is empty',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2),
                    fontSize: 13,
                  ),
                ),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              itemCount: items.length,
              separatorBuilder: (context, index) => Divider(
                color: Colors.white.withValues(alpha: 0.04),
                height: 24,
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final parsed = _parseQueueItem(item.text, index);

                return InkWell(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      item.done = !item.done;
                    });
                    _saveChanges();
                  },
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    setState(() {
                      _projectData.folders['General']!.removeAt(index);
                    });
                    _saveChanges();
                  },
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              parsed.cleanText,
                              style: TextStyle(
                                color: item.done ? Colors.white.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.85),
                                fontSize: 15,
                                decoration: item.done ? TextDecoration.lineThrough : null,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                if (parsed.versionTag != null) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.12),
                                      ),
                                    ),
                                    child: Text(
                                      parsed.versionTag!,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.4),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  parsed.timeAgo,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.25),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline_rounded,
                          color: Colors.white.withValues(alpha: 0.15),
                          size: 18,
                        ),
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          setState(() {
                            _projectData.folders['General']!.removeAt(index);
                          });
                          _saveChanges();
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folderNames = _projectData.folders.keys.where((k) => k != 'General').toList();
    final generalItems = _projectData.folders['General'] ?? [];

    return Scaffold(
      backgroundColor: _surfaceBase,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 24),
          onPressed: () {
            HapticFeedback.lightImpact();
            Navigator.pop(context);
          },
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _projectData.name,
              style: const TextStyle(
                color: Color(0xFFD3C2F0), // Lavender purple
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${folderNames.length} FOLDERS',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        actions: [
          Center(
            child: AnimatedCrossFade(
              firstChild: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _accentBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        valueColor: AlwaysStoppedAnimation<Color>(_accentBlue),
                      ),
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Saving',
                      style: TextStyle(
                        color: _accentBlue,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              secondChild: const SizedBox.shrink(),
              crossFadeState: _isSaving ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              duration: const Duration(milliseconds: 200),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: const Color(0xFF1D1B20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (val) {
              if (val == 'add_folder') {
                _showAddFolderDialog();
              } else if (val == 'audit') {
                HapticFeedback.mediumImpact();
                _auditProjectCanvas();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'add_folder',
                child: Row(
                  children: [
                    Icon(Icons.create_new_folder_outlined, color: Colors.white70, size: 18),
                    SizedBox(width: 8),
                    Text('Add Folder', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'audit',
                child: Row(
                  children: [
                    Icon(Icons.analytics_outlined, color: Colors.white70, size: 18),
                    SizedBox(width: 8),
                    Text('Audit Project', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: DotGridPainter(),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: folderNames.length,
                          itemBuilder: (context, index) {
                            final folder = folderNames[index];
                            final items = _projectData.folders[folder]!;
                            return _buildFolderListCard(folder, items);
                          },
                        ),
                        const SizedBox(height: 24),
                        Text(
                          "UNSORTED QUEUE",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildUnsortedQueueCard(generalItems),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 150),
                      alignment: Alignment.bottomLeft,
                      child: _buildInputSuggestionBar(),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1D1B20).withValues(alpha: 0.65),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                                width: 1,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 24,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: _inputController,
                                  focusNode: _inputFocusNode,
                                  minLines: 1,
                                  maxLines: 5,
                                  textInputAction: TextInputAction.newline,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w400,
                                    height: 1.4,
                                  ),
                                  cursorColor: const Color(0xFFA8C7FA),
                                  decoration: InputDecoration(
                                    hintText: 'What\'s on your mind?...',
                                    hintStyle: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.35),
                                      fontSize: 16,
                                      height: 1.4,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    _buildManualFolderSelector(),
                                    const Spacer(),
                                    IconButton(
                                      icon: Icon(
                                        Icons.attachment_rounded,
                                        color: Colors.white.withValues(alpha: 0.6),
                                        size: 24,
                                      ),
                                      onPressed: () => _pickImageForFolder('General'),
                                    ),
                                    const SizedBox(width: 8),
                                    GestureDetector(
                                      onTap: () => _routeCommandInput(_inputController.text),
                                      child: Container(
                                        height: 44,
                                        width: 44,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFFA8C7FA),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.arrow_upward_rounded,
                                          color: Color(0xFF1D1B20),
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputSuggestionBar() {
    if (_mentionQuery == null) return const SizedBox.shrink();
    
    final matchedFolders = _getMatchedFolders(_mentionQuery!);
    if (matchedFolders.isEmpty) return const SizedBox.shrink();
    
    return Container(
      height: 38,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: matchedFolders.length,
        itemBuilder: (context, index) {
          final folder = matchedFolders[index];
          final color = _getFolderColor(folder);
          final icon = _getFolderIcon(folder);
          
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () => _applyFolderSuggestionValue(folder),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withValues(alpha: 0.25)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: color, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      '@$folder',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildManualFolderSelector() {
    final currentTarget = _determineTargetFolder(_inputController.text);
    final color = _getFolderColor(currentTarget);
    final icon = _getFolderIcon(currentTarget);
    final isLocked = _manuallySelectedFolder != null;

    return Theme(
      data: Theme.of(context).copyWith(
        cardColor: const Color(0xFF1D1B20),
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Select Target Folder',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: const Color(0xFF1D1B20),
        onSelected: (folder) {
          HapticFeedback.selectionClick();
          setState(() {
            if (folder == '__auto__') {
              _manuallySelectedFolder = null;
            } else {
              _manuallySelectedFolder = folder;
            }
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isLocked ? color : color.withValues(alpha: 0.25),
              width: isLocked ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isLocked ? Icons.lock_outline_rounded : icon,
                color: color,
                size: 14,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  currentTarget,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down_rounded,
                color: color.withValues(alpha: 0.6),
                size: 16,
              ),
            ],
          ),
        ),
        itemBuilder: (context) {
          final folders = _projectData.folders.keys.toList();
          return [
            PopupMenuItem<String>(
              value: '__auto__',
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    color: _manuallySelectedFolder == null ? const Color(0xFFA8C7FA) : Colors.white60,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Auto-classify',
                    style: TextStyle(
                      color: _manuallySelectedFolder == null ? const Color(0xFFA8C7FA) : Colors.white,
                      fontSize: 14,
                      fontWeight: _manuallySelectedFolder == null ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(height: 1),
            ...folders.map((f) {
              final folderColor = _getFolderColor(f);
              final folderIcon = _getFolderIcon(f);
              final isSelected = _manuallySelectedFolder == f;
              return PopupMenuItem<String>(
                value: f,
                child: Row(
                  children: [
                    Icon(folderIcon, color: folderColor, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      f,
                      style: TextStyle(
                        color: isSelected ? folderColor : Colors.white,
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ];
        },
      ),
    );
  }

  void _auditProjectCanvas() {
    final textForAudit = jsonEncode(_projectData.toJson());
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return FutureBuilder<String>(
          future: Future.delayed(const Duration(milliseconds: 800), () => auditProject(projectText: textForAudit)),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const AlertDialog(
                backgroundColor: Color(0xFF1D1B20),
                content: Row(
                  children: [
                    CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFA8C7FA))),
                    SizedBox(width: 16),
                    Text('Auditing project canvas...', style: TextStyle(color: Colors.white)),
                  ],
                ),
              );
            }
            return AlertDialog(
              backgroundColor: const Color(0xFF1D1B20),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.analytics_outlined, color: Color(0xFFA8C7FA)),
                  SizedBox(width: 8),
                  Text('Project Audit', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: SingleChildScrollView(
                child: Text(
                  snapshot.data ?? 'Audit failed to run.',
                  style: const TextStyle(color: Colors.white70, height: 1.4),
                ),
              ),
              actions: [
                 TextButton(
                   onPressed: () {
                     HapticFeedback.lightImpact();
                     Navigator.pop(context);
                   },
                   child: const Text('Close', style: TextStyle(color: Color(0xFFA8C7FA))),
                 ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ParsedQueueItem {
  final String cleanText;
  final String? versionTag;
  final String timeAgo;

  _ParsedQueueItem({required this.cleanText, this.versionTag, required this.timeAgo});
}

class DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.03)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    const double spacing = 20.0;
    for (double x = spacing / 2; x < size.width; x += spacing) {
      for (double y = spacing / 2; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
