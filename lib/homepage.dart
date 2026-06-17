import 'package:fastreminder/src/rust/api/classifiers.dart';
import 'package:fastreminder/src/rust/api/simple.dart';
import 'package:fastreminder/src/rust/api/schema.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:android_intent_plus/android_intent.dart';
import 'package:fastreminder/note_editor_page.dart';
import 'package:fastreminder/project_canvas_page.dart';

class Homeapp extends StatefulWidget {
  const Homeapp({super.key});

  @override
  State<Homeapp> createState() => _HomeappState();
}

// Map folder names to icons for the pills
const Map<String, IconData> _folderIcons = {
  'General': Icons.inbox_rounded,
  'Kichapi': Icons.star_rounded,
  'College': Icons.school_rounded,
  'Social': Icons.people_rounded,
  'Work': Icons.work_rounded,
  'Home': Icons.home_rounded,
  'Health': Icons.favorite_rounded,
  'Finance': Icons.account_balance_wallet_rounded,
};

// Accent colors for note cards — Google Pixel Material You pastels
const List<Color> _accentColors = [
  Color(0xFFA8C7FA), // Soft Blue
  Color(0xFFC4E7C4), // Soft Green
  Color(0xFFFAD8C2), // Soft Peach/Amber
  Color(0xFFE8DEF8), // Soft Purple
  Color(0xFFF2B8B5), // Soft Coral/Rose
  Color(0xFFB2EBF2), // Soft Teal
];

class _CommandShortcut {
  final String command;
  final String label;
  final String description;
  final IconData icon;
  final Color color;

  const _CommandShortcut({
    required this.command,
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
  });
}

const List<_CommandShortcut> _commands = [
  _CommandShortcut(
    command: '/l',
    label: 'Checklist',
    description: 'Create a checklist (e.g. /l Groceries)',
    icon: Icons.playlist_add_check_rounded,
    color: Color(0xFFC4E7C4), // Soft Green
  ),
  _CommandShortcut(
    command: '/a',
    label: 'Alarm',
    description: 'Create an alarm (e.g. /a meeting in 10m)',
    icon: Icons.alarm_rounded,
    color: Color(0xFFA8C7FA), // Soft Blue
  ),
  _CommandShortcut(
    command: '/n',
    label: 'Note',
    description: 'Create a note page (e.g. /n Journal)',
    icon: Icons.description_rounded,
    color: Color(0xFFFAD8C2), // Soft Peach/Amber
  ),
  _CommandShortcut(
    command: '/p',
    label: 'Project',
    description: 'Create or open project canvas (e.g. /p fmn)',
    icon: Icons.grid_view_rounded,
    color: Color(0xFFE8DEF8), // Soft Purple
  ),
  _CommandShortcut(
    command: '/c',
    label: 'Counter',
    description: 'Create a counter (e.g. /c Push-ups)',
    icon: Icons.add_circle_outline_rounded,
    color: Color(0xFFB2EBF2), // Soft Teal
  ),
];

class _HomeappState extends State<Homeapp> {
  late TextEditingController maintext;
  final FocusNode _mainFocusNode = FocusNode();
  String detectedFolder = "General";
  double importanceValue = 0.5;
  String activeFilter = "General";
  late Stream<List<Reminder>> _reminderStream;
  String? selectedAttachmentPath;
  final ImagePicker _picker = ImagePicker();

  Set<String> _cachedFolders = {"General"};
  String? _activeSuggestion;
  String? _mentionQuery;
  String? _activeCommand;
  String? _activeCommandDescription;
  List<Reminder> _allReminders = [];
  Timer? _expiryTimer;
  Timer? _classifyDebounce;

  Map<String, Color> _folderColors = {};

  void _applyCommand(String cmd) {
    setState(() {
      maintext.text = '$cmd ';
      maintext.selection = TextSelection.fromPosition(
        TextPosition(offset: maintext.text.length),
      );
    });
    _mainFocusNode.requestFocus();
  }

  void _applyFolderSuggestion() {
    HapticFeedback.lightImpact();
    if (_activeSuggestion == null) return;
    final text = maintext.text;
    final cursorPosition = maintext.selection.baseOffset;
    if (cursorPosition >= 0 && cursorPosition <= text.length) {
      final textBeforeCursor = text.substring(0, cursorPosition);
      final match = RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(textBeforeCursor);
      if (match != null) {
        final suggestion = _activeSuggestion!;
        final replacedText =
            textBeforeCursor.substring(0, match.start) +
            '@' +
            suggestion +
            ' ' +
            text.substring(cursorPosition);
        final newOffset = match.start + suggestion.length + 2;

        setState(() {
          maintext.value = TextEditingValue(
            text: replacedText,
            selection: TextSelection.collapsed(offset: newOffset),
          );
          _activeSuggestion = null;
          _mentionQuery = null;
        });
        _mainFocusNode.requestFocus();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    maintext = CommandTextEditingController();
    maintext.addListener(_onTextChanged);
    _reminderStream = getReminderStream();
    _loadFolderColors();
    _startExpiryCheck();
  }

  void _startExpiryCheck() {
    _expiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _checkAndCleanExpiredReminders();
    });
  }

  void _checkAndCleanExpiredReminders() {
    final now = DateTime.now();
    for (final r in _allReminders) {
      final alarm = tryParseAlarm(r.context);
      if (alarm != null) {
        final timerDuration = _getTimerDuration(alarm.text);
        if (timerDuration != null) {
          final startTime = DateTime.fromMillisecondsSinceEpoch(
            r.dateOfCreation.toInt() * 1000,
          );
          final endTime = startTime.add(timerDuration);
          if (now.isAfter(endTime)) {
            if (r.id != null) {
              deleteReminder(id: r.id!);
            }
          }
        }
      }
    }
  }

  String _getDisplayText(Reminder r) {
    final alarm = tryParseAlarm(r.context);
    if (alarm != null) {
      return alarm.text;
    }
    final checklist = tryParseChecklist(r.context);
    if (checklist != null) {
      return checklist.title;
    }
    final note = tryParseNote(r.context);
    if (note != null) {
      return note.title;
    }
    final project = tryParseProject(r.context);
    if (project != null) {
      return project.name;
    }
    final counter = tryParseCounter(r.context);
    if (counter != null) {
      return counter.title;
    }
    return r.context;
  }

  Duration? _getReminderTimerDuration(Reminder r) {
    final alarm = tryParseAlarm(r.context);
    if (alarm != null) {
      return _getTimerDuration(alarm.text);
    }
    final checklist = tryParseChecklist(r.context);
    if (checklist != null) {
      return null;
    }
    final note = tryParseNote(r.context);
    if (note != null) {
      return null;
    }
    final project = tryParseProject(r.context);
    if (project != null) {
      return null;
    }
    final counter = tryParseCounter(r.context);
    if (counter != null) {
      return null;
    }
    return _getTimerDuration(r.context);
  }

  void _loadFolderColors() {
    final colors = getFolderColors();
    setState(() {
      for (final fc in colors) {
        // Rust returns hex string, Flutter uses 0xAARRGGBB
        try {
          _folderColors[fc.folder] = Color(int.parse(fc.color, radix: 16));
        } catch (e) {
          // Ignore invalid colors
        }
      }
    });
  }

  void _updateFolderColor(String folder, Color color) {
    updateFolderColor(folder: folder, color: color.value.toRadixString(16));
    setState(() {
      _folderColors[folder] = color;
    });
  }

  Color _getFolderColor(String folder) {
    return _folderColors[folder] ?? _getDefaultColor(folder);
  }

  Color _getDefaultColor(String folder) {
    final index = folder.hashCode.abs() % _accentColors.length;
    return _accentColors[index];
  }

  void _showColorPicker(String folder) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(
            'Select color for $folder',
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children:
                  [
                    ..._accentColors,
                    const Color(0xFF01579B), // dark light blue
                    const Color(0xFF827717), // dark lime
                    const Color(0xFF33691E), // dark light green
                    const Color(0xFF006064), // dark cyan
                    const Color(0xFF1A237E), // dark indigo
                    const Color(0xFFBF360C), // dark deep orange
                    const Color(0xFF3E2723), // dark brown
                    const Color(0xFF212121), // dark grey
                    const Color(0xFF263238), // dark blue grey
                    const Color(0xFF880E4F), // dark pink
                    const Color(0xFF311B92), // dark deep purple
                    Colors.pinkAccent, // preserved pink
                  ].map((color) {
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _updateFolderColor(folder, color);
                        Navigator.of(context).pop();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).pop();
              },
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickMedia() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (BuildContext bc) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.white),
                title: const Text(
                  'Photo Library',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).pop();
                  final XFile? image = await _picker.pickImage(
                    source: ImageSource.gallery,
                  );
                  if (image != null) _saveMediaToAppDir(image.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library, color: Colors.white),
                title: const Text(
                  'Video Library',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).pop();
                  final XFile? video = await _picker.pickVideo(
                    source: ImageSource.gallery,
                  );
                  if (video != null) _saveMediaToAppDir(video.path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud, color: Colors.white),
                title: const Text(
                  'Browse Files & Cloud (Google Photos)',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  HapticFeedback.lightImpact();
                  Navigator.of(context).pop();
                  final FilePickerResult? result = await FilePicker.pickFiles(
                    type: FileType.media,
                  );
                  if (result != null && result.files.single.path != null) {
                    _saveMediaToAppDir(result.files.single.path!);
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _saveMediaToAppDir(String path) async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final fileName = p.basename(path);
    final savedFile = await File(path).copy('${appDocDir.path}/$fileName');
    setState(() {
      selectedAttachmentPath = savedFile.path;
    });
  }

  void _handleFolderSelection(String folder) {
    HapticFeedback.lightImpact();
    final currentText = maintext.text;
    
    String newText = currentText;
    for (final f in _cachedFolders) {
      if (f.toLowerCase() != 'general') {
        newText = newText.replaceAll(RegExp('@${f}\\b', caseSensitive: false), '').replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }
    
    if (folder.toLowerCase() != 'general') {
      newText = newText.isNotEmpty 
          ? '$newText @$folder ' 
          : '@$folder ';
    } else {
      newText = newText.isNotEmpty ? '$newText ' : '';
    }
    
    maintext.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
    _mainFocusNode.requestFocus();
  }

  Future<void> _pickTimer() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.greenAccent,
              onPrimary: Colors.black,
              surface: Color(0xFF1A1A1A),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate != null) {
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
        builder: (context, child) {
          return Theme(
            data: ThemeData.dark().copyWith(
              colorScheme: const ColorScheme.dark(
                primary: Colors.greenAccent,
                onPrimary: Colors.black,
                surface: Color(0xFF1A1A1A),
                onSurface: Colors.white,
              ),
            ),
            child: child!,
          );
        },
      );

      if (pickedTime != null) {
        final selectedDateTime = DateTime(
          pickedDate.year,
          pickedDate.month,
          pickedDate.day,
          pickedTime.hour,
          pickedTime.minute,
        );

        final duration = selectedDateTime.difference(DateTime.now());
        if (duration.isNegative) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Please select a future time.')),
            );
          }
          return;
        }

        final currentText = maintext.text;
        final newText = currentText.isNotEmpty && !currentText.endsWith(' ')
            ? '$currentText in ${duration.inMinutes}m'
            : '${currentText}in ${duration.inMinutes}m';

        setState(() {
          maintext.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: newText.length),
          );
        });
      }
    }
  }

  void _onTextChanged() {
    final text = maintext.text;
    final cursorPosition = maintext.selection.baseOffset;

    // Check if space was typed and we have a suggestion
    if (cursorPosition > 0 &&
        cursorPosition <= text.length &&
        text[cursorPosition - 1] == ' ' &&
        _activeSuggestion != null) {
      final textBeforeSpace = text.substring(0, cursorPosition - 1);
      final lastWordMatch = RegExp(
        r'@([a-zA-Z0-9_]*)$',
      ).firstMatch(textBeforeSpace);
      if (lastWordMatch != null) {
        final query = lastWordMatch.group(1)!;
        if (_activeSuggestion!.toLowerCase().startsWith(query.toLowerCase())) {
          // Auto complete!
          final suggestion = _activeSuggestion!;
          final replacedText =
              textBeforeSpace.substring(0, lastWordMatch.start) +
              '@' +
              suggestion +
              ' ' +
              text.substring(cursorPosition);
          final newOffset = lastWordMatch.start + suggestion.length + 2;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              maintext.value = TextEditingValue(
                text: replacedText,
                selection: TextSelection.collapsed(offset: newOffset),
              );
            }
          });
          setState(() {
            _activeSuggestion = null;
            _mentionQuery = null;
          });
          return;
        }
      }
    }

    // Normal typing, find active suggestion
    if (cursorPosition >= 0 && cursorPosition <= text.length) {
      final textBeforeCursor = text.substring(0, cursorPosition);
      final match = RegExp(r'@([a-zA-Z0-9_]*)$').firstMatch(textBeforeCursor);

      if (match != null) {
        _mentionQuery = match.group(1)!;
        final matches = _cachedFolders
            .where(
              (f) => f.toLowerCase().startsWith(_mentionQuery!.toLowerCase()),
            )
            .toList();
        if (matches.isNotEmpty) {
          _activeSuggestion = matches.first;
        } else {
          _activeSuggestion = null;
        }
      } else {
        _mentionQuery = null;
        _activeSuggestion = null;
      }
    }

    // Check for slash command suggestions
    String? activeCommand;
    String? activeCommandDescription;
    if (text.startsWith('/')) {
      final spaceIndex = text.indexOf(' ');
      final cmd = spaceIndex == -1 ? text : text.substring(0, spaceIndex);

      final commandMatch = _commands.where((c) => c.command == cmd).toList();
      if (commandMatch.isNotEmpty) {
        activeCommand = commandMatch.first.command;
        activeCommandDescription = commandMatch.first.description;
      } else if (cmd == '/') {
        activeCommand = '/';
        activeCommandDescription = 'Show commands';
      }
    }

    setState(() {
      _activeCommand = activeCommand;
      _activeCommandDescription = activeCommandDescription;
    });

    // Debounce the expensive folder classification
    _classifyDebounce?.cancel();
    _classifyDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final currentText = maintext.text;
      String newFolder;
      if (currentText.isEmpty) {
        newFolder = "General";
      } else {
        String? explicitFolder;
        // Check if any existing folder is mentioned in the text
        for (final folder in _cachedFolders) {
          if (folder.toLowerCase() != 'general' &&
              currentText.toLowerCase().contains('@${folder.toLowerCase()}')) {
            explicitFolder = folder;
            break; // take the first matched one
          }
        }

        if (explicitFolder != null) {
          newFolder = explicitFolder;
        } else {
          newFolder = classifyIntent(context: currentText);
        }
      }
      if (mounted && newFolder != detectedFolder) {
        setState(() {
          detectedFolder = newFolder;
        });
      }
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _classifyDebounce?.cancel();
    maintext.removeListener(_onTextChanged);
    maintext.dispose();
    super.dispose();
  }

  Widget _buildSuggestionBar() {
    final showCommand =
        _activeCommand != null && _activeCommandDescription != null;
    final showMention = _mentionQuery != null && _activeSuggestion != null;

    if (!showCommand && !showMention) {
      return const SizedBox.shrink();
    }

    Widget? commandWidget;
    if (showCommand) {
      if (_activeCommand == '/') {
        commandWidget = Padding(
          padding: const EdgeInsets.only(
            left: 12,
            top: 12,
            bottom: 4,
            right: 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.terminal_rounded,
                    color: Color(0xFFA8C7FA),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "COMMANDS",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _commands.length,
                  itemBuilder: (context, index) {
                    final cmd = _commands[index];
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _applyCommand(cmd.command);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: cmd.color.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: cmd.color.withOpacity(0.25),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cmd.icon, color: cmd.color, size: 16),
                              const SizedBox(width: 8),
                              Text(
                                cmd.command,
                                style: TextStyle(
                                  color: cmd.color,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                cmd.label,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      } else {
        final cmdInfo = _commands.firstWhere(
          (c) => c.command == _activeCommand,
          orElse: () => _CommandShortcut(
            command: _activeCommand!,
            label: '',
            description: _activeCommandDescription!,
            icon: Icons.terminal_rounded,
            color: Colors.greenAccent,
          ),
        );

        commandWidget = Padding(
          padding: const EdgeInsets.only(left: 12, top: 12, bottom: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cmdInfo.color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cmdInfo.color.withOpacity(0.25)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(cmdInfo.icon, color: cmdInfo.color, size: 16),
                const SizedBox(width: 8),
                Text(
                  cmdInfo.command,
                  style: TextStyle(
                    color: cmdInfo.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  cmdInfo.description,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    Widget? mentionWidget;
    if (showMention) {
      mentionWidget = Padding(
        padding: const EdgeInsets.only(left: 12, top: 8, bottom: 4),
        child: GestureDetector(
          onTap: _applyFolderSuggestion,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFA8C7FA).withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFFA8C7FA).withOpacity(0.25),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.folder_rounded,
                  color: Color(0xFFA8C7FA),
                  size: 14,
                ),
                const SizedBox(width: 8),
                Text(
                  '@$_activeSuggestion',
                  style: const TextStyle(
                    color: Color(0xFFA8C7FA),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(Tap to choose)',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (commandWidget != null) commandWidget,
        if (mentionWidget != null) mentionWidget,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0x33000000),
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: const Color(0xFF121318),
        body: SafeArea(
          child: StreamBuilder<List<Reminder>>(
            stream: _reminderStream,
            builder: (context, snapshot) {
              final allReminders = snapshot.data?.reversed.toList() ?? [];
              _allReminders = allReminders;

              final folders = [
                "General",
                ...allReminders
                    .map((r) => r.folder)
                    .toSet()
                    .where((f) => f.toLowerCase() != 'general'),
              ];
              _cachedFolders = folders.toSet();

              final reminders = activeFilter == "General"
                  ? allReminders
                  : allReminders
                        .where((r) => r.folder == activeFilter)
                        .toList();

              final pinnedReminders = reminders
                  .where((r) => r.isPinned)
                  .toList();

              return GestureDetector(
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity == null) return;
                  if (details.primaryVelocity! < -300) {
                    // Swipe left: go to next folder
                    final currentIndex = folders.indexOf(activeFilter);
                    if (currentIndex < folders.length - 1) {
                      HapticFeedback.lightImpact();
                      setState(() {
                        activeFilter = folders[currentIndex + 1];
                      });
                    }
                  } else if (details.primaryVelocity! > 300) {
                    // Swipe right: go to previous folder
                    final currentIndex = folders.indexOf(activeFilter);
                    if (currentIndex > 0) {
                      HapticFeedback.lightImpact();
                      setState(() {
                        activeFilter = folders[currentIndex - 1];
                      });
                    }
                  }
                },
                child: CustomScrollView(
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  slivers: [
                  CupertinoSliverRefreshControl(
                    onRefresh: () async {
                      HapticFeedback.mediumImpact();
                      await Future.delayed(const Duration(milliseconds: 1500));
                      setState(() {});
                    },
                  ),
                  // Top section containing the reminder input card
                  SliverToBoxAdapter(
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        children: [
                          Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 24,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1D1B20),
                              borderRadius: BorderRadius.circular(32),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.08),
                                width: 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Always-present suggestion slot — keeps Column children count stable
                                // so the TextField below never changes index and never loses focus.
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 150),
                                  alignment: Alignment.topLeft,
                                  child: _buildSuggestionBar(),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: TextField(
                                    controller: maintext,
                                    focusNode: _mainFocusNode,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w400,
                                      letterSpacing: -0.2,
                                    ),
                                    maxLines: null,
                                    minLines: 4,
                                    cursorColor: const Color(0xFFA8C7FA),
                                    decoration: InputDecoration(
                                      hintText: "What's on your mind?",
                                      hintStyle: TextStyle(
                                        color: Colors.white.withOpacity(0.25),
                                        fontSize: 20,
                                        fontWeight: FontWeight.w400,
                                      ),
                                      border: InputBorder.none,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            vertical: 16,
                                          ),
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        icon: Icon(
                                          Icons.attachment_rounded,
                                          color: selectedAttachmentPath != null
                                              ? const Color(0xFFA8C7FA)
                                              : Colors.white.withOpacity(0.5),
                                          size: 22,
                                        ),
                                        onPressed: () {
                                          HapticFeedback.lightImpact();
                                          _mainFocusNode.unfocus();
                                          _pickMedia();
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          Icons.schedule_rounded,
                                          color: Colors.white.withOpacity(0.5),
                                          size: 22,
                                        ),
                                        onPressed: () {
                                          HapticFeedback.lightImpact();
                                          _mainFocusNode.unfocus();
                                          _pickTimer();
                                        },
                                      ),
                                      const SizedBox(width: 4),
                                      Builder(
                                        builder: (context) {
                                          return GestureDetector(
                                            onTap: () async {
                                              HapticFeedback.lightImpact();
                                              final RenderBox button = context.findRenderObject() as RenderBox;
                                              final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
                                              final RelativeRect position = RelativeRect.fromRect(
                                                Rect.fromPoints(
                                                  button.localToGlobal(Offset(0, -10), ancestor: overlay), // Pop slightly above
                                                  button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
                                                ),
                                                Offset.zero & overlay.size,
                                              );
                                              
                                              final selectedFolder = await showMenu<String>(
                                                context: context,
                                                position: position,
                                                color: const Color(0xFF1D1B20),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                                items: _cachedFolders.map((folder) {
                                                  final folderColor = _getFolderColor(folder);
                                                  return PopupMenuItem<String>(
                                                    value: folder,
                                                    child: Row(
                                                      children: [
                                                        Container(
                                                          padding: const EdgeInsets.all(6),
                                                          decoration: BoxDecoration(
                                                            color: folderColor.withOpacity(0.12),
                                                            shape: BoxShape.circle,
                                                          ),
                                                          child: Icon(
                                                            _folderIcons[folder] ?? Icons.folder_rounded,
                                                            color: folderColor,
                                                            size: 16,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 12),
                                                        Text(
                                                          folder,
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 14,
                                                            fontWeight: FontWeight.w500,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }).toList(),
                                              );
                                              
                                              if (selectedFolder != null) {
                                                _handleFolderSelection(selectedFolder);
                                              }
                                            },
                                            child: _buildTag(detectedFolder),
                                          );
                                        }
                                      ),
                                      const Spacer(),
                                      GestureDetector(
                                        onTap: () async {
                                          HapticFeedback.heavyImpact();
                                          _mainFocusNode.unfocus();
                                          if (maintext.text.isNotEmpty ||
                                              selectedAttachmentPath != null) {
                                            final currentText = maintext.text;
                                            final bool isListCommand =
                                                currentText.trim() == '/l' ||
                                                currentText.startsWith('/l ');
                                            final bool isAlarmCommand =
                                                currentText.trim() == '/a' ||
                                                currentText.startsWith('/a ');
                                            final bool isNoteCommand =
                                                currentText.trim() == '/n' ||
                                                currentText.startsWith('/n ');
                                            final bool isProjectCommand =
                                                currentText.trim() == '/p' ||
                                                currentText.startsWith('/p ');
                                            final bool isCounterCommand =
                                                currentText.trim() == '/c' ||
                                                currentText.startsWith('/c ');

                                            String reminderContext =
                                                currentText;
                                            if (isListCommand) {
                                              String title = "List";
                                              if (currentText.trim() == '/l') {
                                                title = "List";
                                              } else if (currentText.startsWith(
                                                '/l ',
                                              )) {
                                                title = currentText
                                                    .substring(3)
                                                    .trim();
                                                if (title.isEmpty)
                                                  title = "List";
                                              }
                                              final checklist = ChecklistData(
                                                title: title,
                                                items: [],
                                              );
                                              reminderContext = jsonEncode(
                                                checklist.toJson(),
                                              );
                                            } else if (isAlarmCommand) {
                                              String text = "";
                                              if (currentText.trim() == '/a') {
                                                text = "Alarm";
                                              } else if (currentText.startsWith(
                                                '/a ',
                                              )) {
                                                text = currentText
                                                    .substring(3)
                                                    .trim();
                                                if (text.isEmpty)
                                                  text = "Alarm";
                                              }

                                              // Ensure there is a duration, if not, append default so it has one
                                              final duration =
                                                  _getTimerDuration(text);
                                              if (duration == null) {
                                                text = "$text in 1m";
                                              }

                                              final alarm = AlarmData(
                                                text: text,
                                              );
                                              reminderContext = jsonEncode(
                                                alarm.toJson(),
                                              );

                                              // Set system alarm
                                              final parsedDuration =
                                                  _getTimerDuration(text);
                                              if (parsedDuration != null) {
                                                final alarmTime = DateTime.now().add(parsedDuration);
                                                final intent = AndroidIntent(
                                                  action: 'android.intent.action.SET_ALARM',
                                                  arguments: <String, dynamic>{
                                                    'android.intent.extra.alarm.HOUR': alarmTime.hour,
                                                    'android.intent.extra.alarm.MINUTES': alarmTime.minute,
                                                    'android.intent.extra.alarm.MESSAGE': text,
                                                    'android.intent.extra.alarm.SKIP_UI': true,
                                                  },
                                                );
                                                try {
                                                  await intent.launch();
                                                } catch (e) {
                                                  debugPrint(
                                                    "Failed to set alarm: $e",
                                                  );
                                                }
                                              }
                                            } else if (isNoteCommand) {
                                              String title = "Note";
                                              if (currentText.trim() == '/n') {
                                                title = "Note";
                                              } else if (currentText.startsWith(
                                                '/n ',
                                              )) {
                                                title = currentText
                                                    .substring(3)
                                                    .trim();
                                                if (title.isEmpty)
                                                  title = "Note";
                                              }
                                              final noteData = NoteData(
                                                title: title,
                                                content: "",
                                              );
                                              reminderContext = jsonEncode(
                                                noteData.toJson(),
                                              );
                                            } else if (isProjectCommand) {
                                              final content = currentText
                                                  .trim();
                                              String projectName = "Project";
                                              String? targetFolder;
                                              String? itemText;

                                              if (content == '/p') {
                                                projectName = "Project";
                                              } else {
                                                final rawArgs = content
                                                    .substring(3)
                                                    .trim();
                                                final spaceIndex = rawArgs
                                                    .indexOf(' ');
                                                if (spaceIndex == -1) {
                                                  projectName = rawArgs;
                                                } else {
                                                  projectName = rawArgs
                                                      .substring(0, spaceIndex)
                                                      .trim();
                                                  final remaining = rawArgs
                                                      .substring(spaceIndex + 1)
                                                      .trim();

                                                  if (remaining.startsWith(
                                                    ':',
                                                  )) {
                                                    final colonSpaceIndex =
                                                        remaining.indexOf(' ');
                                                    if (colonSpaceIndex != -1) {
                                                      targetFolder = remaining
                                                          .substring(
                                                            1,
                                                            colonSpaceIndex,
                                                          )
                                                          .trim();
                                                      itemText = remaining
                                                          .substring(
                                                            colonSpaceIndex + 1,
                                                          )
                                                          .trim();
                                                    } else {
                                                      targetFolder = remaining
                                                          .substring(1)
                                                          .trim();
                                                      itemText = '';
                                                    }
                                                  } else {
                                                    itemText = remaining;
                                                    targetFolder =
                                                        classifyIntent(
                                                          context: itemText,
                                                        );
                                                  }
                                                }
                                              }

                                              if (projectName.isEmpty)
                                                projectName = "Project";

                                              Reminder? existingProject;
                                              ProjectData? existingData;
                                              for (final r in _allReminders) {
                                                final pData = tryParseProject(
                                                  r.context,
                                                );
                                                if (pData != null &&
                                                    pData.name.toLowerCase() ==
                                                        projectName
                                                            .toLowerCase()) {
                                                  existingProject = r;
                                                  existingData = pData;
                                                  break;
                                                }
                                              }

                                              if (existingProject != null &&
                                                  existingData != null) {
                                                if (targetFolder != null &&
                                                    itemText != null &&
                                                    itemText.isNotEmpty) {
                                                  final folderName =
                                                      targetFolder;
                                                  final text = itemText;
                                                  final data = existingData;
                                                  setState(() {
                                                    String actualFolderKey =
                                                        folderName;
                                                    for (final key
                                                        in data.folders.keys) {
                                                      if (key.toLowerCase() ==
                                                          folderName
                                                              .toLowerCase()) {
                                                        actualFolderKey = key;
                                                        break;
                                                      }
                                                    }
                                                    if (!data.folders
                                                        .containsKey(
                                                          actualFolderKey,
                                                        )) {
                                                      data.folders[actualFolderKey] =
                                                          [];
                                                    }
                                                    data.folders[actualFolderKey]!
                                                        .add(
                                                          ProjectItem(
                                                            text: text,
                                                            done: false,
                                                          ),
                                                        );
                                                  });
                                                  updateReminderContext(
                                                    id: existingProject.id!,
                                                    context: jsonEncode(
                                                      existingData.toJson(),
                                                    ),
                                                  );
                                                } else {
                                                  _openProjectCanvas(
                                                    existingProject,
                                                    existingData,
                                                  );
                                                }
                                                maintext.clear();
                                                return;
                                              } else {
                                                final Map<
                                                  String,
                                                  List<ProjectItem>
                                                >
                                                folders = {
                                                  'General': [],
                                                  'UI/UX': [],
                                                  'Backend': [],
                                                  'Database': [],
                                                  'Icebox': [],
                                                };

                                                if (targetFolder != null &&
                                                    itemText != null &&
                                                    itemText.isNotEmpty) {
                                                  String actualFolderKey =
                                                      targetFolder;
                                                  for (final key
                                                      in folders.keys) {
                                                    if (key.toLowerCase() ==
                                                        targetFolder
                                                            .toLowerCase()) {
                                                      actualFolderKey = key;
                                                      break;
                                                    }
                                                  }
                                                  if (!folders.containsKey(
                                                    actualFolderKey,
                                                  )) {
                                                    folders[actualFolderKey] =
                                                        [];
                                                  }
                                                  folders[actualFolderKey]!.add(
                                                    ProjectItem(
                                                      text: itemText,
                                                      done: false,
                                                    ),
                                                  );
                                                }

                                                final newProject = ProjectData(
                                                  name: projectName,
                                                  folders: folders,
                                                );

                                                reminderContext = jsonEncode(
                                                  newProject.toJson(),
                                                );

                                                if (targetFolder == null ||
                                                    itemText == null ||
                                                    itemText.isEmpty) {
                                                  addReminder(
                                                    context: reminderContext,
                                                    importance: 5,
                                                    attachmentPath:
                                                        selectedAttachmentPath,
                                                  );

                                                  Future.delayed(
                                                    const Duration(
                                                      milliseconds: 100,
                                                    ),
                                                    () {
                                                      if (mounted) {
                                                        Reminder? newR;
                                                        for (final r
                                                            in _allReminders) {
                                                          final pData =
                                                              tryParseProject(
                                                                r.context,
                                                              );
                                                          if (pData != null &&
                                                              pData.name
                                                                      .toLowerCase() ==
                                                                  projectName
                                                                      .toLowerCase()) {
                                                            newR = r;
                                                            break;
                                                          }
                                                        }
                                                        if (newR != null) {
                                                          _openProjectCanvas(
                                                            newR,
                                                            newProject,
                                                          );
                                                        }
                                                      }
                                                    },
                                                  );
                                                  maintext.clear();
                                                  setState(() {
                                                    selectedAttachmentPath =
                                                        null;
                                                  });
                                                  return;
                                                }
                                              }
                                            } else if (isCounterCommand) {
                                              String title = "Counter";
                                              if (currentText.trim() == '/c') {
                                                title = "Counter";
                                              } else if (currentText.startsWith(
                                                '/c ',
                                              )) {
                                                title = currentText
                                                    .substring(3)
                                                    .trim();
                                                if (title.isEmpty)
                                                  title = "Counter";
                                              }
                                              final counterData = CounterData(
                                                title: title,
                                                value: 0,
                                              );
                                              reminderContext = jsonEncode(
                                                counterData.toJson(),
                                              );
                                            } else {
                                              final duration =
                                                  _getTimerDuration(
                                                    currentText,
                                                  );
                                              if (duration != null) {
                                                final alarmTime = DateTime.now().add(duration);
                                                final intent = AndroidIntent(
                                                  action:
                                                      'android.intent.action.SET_ALARM',
                                                  arguments: <String, dynamic>{
                                                    'android.intent.extra.alarm.HOUR':
                                                        alarmTime.hour,
                                                    'android.intent.extra.alarm.MINUTES':
                                                        alarmTime.minute,
                                                    'android.intent.extra.alarm.MESSAGE':
                                                        currentText,
                                                    'android.intent.extra.alarm.SKIP_UI':
                                                        true,
                                                  },
                                                );
                                                try {
                                                  await intent.launch();
                                                } catch (e) {
                                                  debugPrint(
                                                    "Failed to set alarm: $e",
                                                  );
                                                }
                                              }
                                            }

                                            addReminder(
                                              context: reminderContext,
                                              importance:
                                                  5, // Default importance
                                              attachmentPath:
                                                  selectedAttachmentPath,
                                            );
                                            maintext.clear();
                                            setState(() {
                                              selectedAttachmentPath = null;
                                            });
                                          }
                                        },
                                        child: Container(
                                          width: 48,
                                          height: 48,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: const Color(0xFFA8C7FA),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(
                                                  0xFFA8C7FA,
                                                ).withOpacity(0.3),
                                                blurRadius: 12,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.arrow_forward_rounded,
                                            color: Color(0xFF121318),
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Folder Pills with icons
                          SizedBox(
                            height: 36,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              itemCount: folders.length,
                              itemBuilder: (context, index) {
                                final folder = folders[index];
                                final isSelected = folder == activeFilter;
                                final icon =
                                    _folderIcons[folder] ??
                                    Icons.folder_rounded;
                                final folderColor = _getFolderColor(folder);

                                return GestureDetector(
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    setState(() {
                                      activeFilter = folder;
                                    });
                                  },
                                  onLongPress: () {
                                    HapticFeedback.mediumImpact();
                                    _showColorPicker(folder);
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    margin: const EdgeInsets.only(right: 10),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 6,
                                    ),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? folderColor.withOpacity(0.24)
                                          : const Color(0xFF1D1B20),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? folderColor.withOpacity(0.7)
                                            : Colors.white.withOpacity(0.08),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          icon,
                                          size: 13,
                                          color: folderColor.withOpacity(0.85),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          folder,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(
                                              0.9,
                                            ),
                                            fontSize: 13,
                                            fontWeight: isSelected
                                                ? FontWeight.w500
                                                : FontWeight.w400,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: folderColor.withOpacity(
                                              0.12,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Text(
                                            '${allReminders.where((r) => folder == "General" || r.folder == folder).length}',
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.6,
                                              ),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                  // Notes list
                  if (reminders.isEmpty)
                    const SliverFillRemaining(child: SizedBox.shrink())
                  else
                    SliverPadding(
                      padding: const EdgeInsets.only(
                        left: 20,
                        right: 20,
                        bottom: 120,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          // Recent Notes section
                          if (reminders.isNotEmpty) ...[
                            const Text(
                              'Recent Notes',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1D1B20),
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Column(
                                children: List.generate(
                                  reminders.length,
                                  (index) => _buildNoteListItem(
                                    reminders[index],
                                    index,
                                    isLast: index == reminders.length - 1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          // Pinned section
                          if (pinnedReminders.isNotEmpty) ...[
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                const Icon(
                                  Icons.star_rounded,
                                  color: Colors.amber,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Pinned',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Pinned cards horizontal scroll
                            SizedBox(
                              height: 140,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: pinnedReminders.length,
                                itemBuilder: (ctx, idx) =>
                                    _buildPinnedCard(pinnedReminders[idx], idx),
                              ),
                            ),
                          ],
                        ]),
                      ),
                    ),
                ],
              ),
              );
            },
          ),
        ),
        extendBody: true,
      ),
    );
  }

  Widget _buildTag(String label, {double fontSize = 12}) {
    final folderColor = _getFolderColor(label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: folderColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: folderColor.withOpacity(0.24), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _folderIcons[label] ?? Icons.folder_rounded,
            size: 14,
            color: folderColor,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: folderColor,
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  Duration? _getTimerDuration(String text) {
    final match = RegExp(
      r'\b(\d+)\s*(m|min|mins|minutes|s|sec|secs|seconds|h|hr|hrs|hours)\b',
      caseSensitive: false,
    ).firstMatch(text);

    if (match != null) {
      final value = int.tryParse(match.group(1)!);
      if (value == null) return null;
      final unit = match.group(2)!.toLowerCase();

      if (unit.startsWith('h')) return Duration(hours: value);
      if (unit.startsWith('m')) return Duration(minutes: value);
      if (unit.startsWith('s')) return Duration(seconds: value);
    }
    return null;
  }

  /// Shows the long-press action sheet for a reminder
  void _showReminderActions(Reminder r) {
    HapticFeedback.heavyImpact();
    final isPinned = r.isPinned;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Preview of the note
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  _getDisplayText(r).length > 80
                      ? '${_getDisplayText(r).substring(0, 80)}…'
                      : _getDisplayText(r),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.45),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              Divider(color: Colors.white.withOpacity(0.08), height: 1),
              // Pin / Unpin
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isPinned ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: Colors.amber,
                    size: 22,
                  ),
                ),
                title: Text(
                  isPinned ? 'Unpin' : 'Pin',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  isPinned
                      ? 'Remove from pinned section'
                      : 'Keep this note at the top',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                  ),
                ),
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.pop(ctx);
                  if (r.id != null) {
                    pinReminder(id: r.id!, pinned: !isPinned);
                  }
                },
              ),
              Divider(
                color: Colors.white.withOpacity(0.08),
                height: 1,
                indent: 20,
              ),
              // Delete
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.delete_rounded,
                    color: Colors.redAccent,
                    size: 22,
                  ),
                ),
                title: const Text(
                  'Delete',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: Text(
                  'Permanently remove this note',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                  ),
                ),
                onTap: () async {
                  HapticFeedback.mediumImpact();
                  Navigator.pop(ctx);
                  if (r.id != null) {
                    final duration = _getReminderTimerDuration(r);
                    if (duration != null) {
                      final intent = AndroidIntent(
                        action: 'android.intent.action.DISMISS_ALARM',
                        arguments: <String, dynamic>{
                          'android.intent.extra.alarm.SEARCH_MODE':
                              'android.label',
                          'android.intent.extra.alarm.MESSAGE': _getDisplayText(
                            r,
                          ),
                        },
                      );
                      try {
                        await intent.launch();
                      } catch (e) {
                        debugPrint("Failed to dismiss alarm: $e");
                      }
                    }
                    deleteReminder(id: r.id!);
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showNoteDetails(Reminder r, Color color) {
    final timerDuration = _getReminderTimerDuration(r);
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      r.dateOfCreation.toInt() * 1000,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0F0F),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(32),
                ),
                border: Border.all(color: color.withOpacity(0.2)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        _buildTag(r.folder, fontSize: 12),
                        const Spacer(),
                        Text(
                          startTime.toString().substring(0, 16),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _getDisplayText(r),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        height: 1.6,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (r.attachmentPath != null) ...[
                      const SizedBox(height: 24),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 240),
                          width: double.infinity,
                          child: Image.file(
                            File(r.attachmentPath!),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ],
                    if (timerDuration != null) ...[
                      const SizedBox(height: 40),
                      Text(
                        'Time Remaining',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 14,
                          letterSpacing: 1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 140,
                              height: 140,
                              child: TimerCircularProgress(
                                startTime: startTime,
                                duration: timerDuration,
                                color: color,
                                size: 140,
                                strokeWidth: 6,
                                interactive: false,
                              ),
                            ),
                            StreamBuilder(
                              stream: Stream.periodic(
                                const Duration(seconds: 1),
                              ),
                              builder: (context, snapshot) {
                                final now = DateTime.now();
                                final endTime = startTime.add(timerDuration);
                                final remaining = endTime.difference(now);

                                if (remaining.isNegative) {
                                  return const Text(
                                    '00:00',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w200,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  );
                                }

                                final minutes = remaining.inMinutes;
                                final seconds = remaining.inSeconds % 60;
                                return Text(
                                  '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w200,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showChecklistDetails(Reminder r, ChecklistData checklist, Color color) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return ChecklistBottomSheet(
          r: r,
          checklist: checklist,
          color: color,
          buildTag: _buildTag,
        );
      },
    );
  }

  void _openNoteEditor(Reminder r, NoteData note, Color color) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            NoteEditorPage(reminder: r, initialNote: note, color: color),
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        opaque: true,
        barrierColor: const Color(0xFF121318),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _openProjectCanvas(Reminder r, ProjectData project) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            ProjectCanvasPage(reminder: r, initialData: project),
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        opaque: true,
        barrierColor: const Color(0xFF0E0E12),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  /// List-style note item for Recent Notes section
  Widget _buildNoteListItem(Reminder r, int index, {bool isLast = false}) {
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      r.dateOfCreation.toInt() * 1000,
    );
    final folderColor = _getFolderColor(r.folder);
    final timerDuration = _getReminderTimerDuration(r);
    final checklist = tryParseChecklist(r.context);
    final note = tryParseNote(r.context);
    final project = tryParseProject(r.context);
    final counter = tryParseCounter(r.context);

    if (counter != null) {
      return GestureDetector(
        onLongPress: () => _showReminderActions(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              // Short colored accent dash
              Container(
                width: 3.5,
                height: 40,
                decoration: BoxDecoration(
                  color: folderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              // Icon badge for Counter
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: folderColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.tag_rounded, color: folderColor, size: 20),
              ),
              const SizedBox(width: 12),
              // Counter title
              Expanded(
                child: Text(
                  counter.title,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              // Counter controls
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCounterButton(
                      icon: Icons.remove_rounded,
                      color: folderColor,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        counter.value--;
                        updateReminderContext(
                          id: r.id!,
                          context: jsonEncode(counter.toJson()),
                        );
                      },
                    ),
                    Container(
                      constraints: const BoxConstraints(minWidth: 40),
                      alignment: Alignment.center,
                      child: Text(
                        '${counter.value}',
                        style: TextStyle(
                          color: folderColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    _buildCounterButton(
                      icon: Icons.add_rounded,
                      color: folderColor,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        counter.value++;
                        updateReminderContext(
                          id: r.id!,
                          context: jsonEncode(counter.toJson()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (project != null) {
      final totalFolders = project.folders.length;
      final totalItems = project.folders.values.fold<int>(
        0,
        (sum, list) => sum + list.length,
      );
      final hasPhotos = project.folders.values.any(
        (list) => list.any((item) => item.photoPath != null),
      );

      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _openProjectCanvas(r, project);
        },
        onLongPress: () => _showReminderActions(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              // Short colored accent dash
              Container(
                width: 3.5,
                height: 40,
                decoration: BoxDecoration(
                  color: folderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              // Icon badge for Project
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: folderColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.grid_view_rounded,
                  color: folderColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              // Project title and stats
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      project.name,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          '$totalFolders folders | $totalItems items',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 12,
                          ),
                        ),
                        if (hasPhotos) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.image_outlined,
                            size: 14,
                            color: Colors.white.withOpacity(0.35),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Date
              Text(
                startTime.toString().substring(0, 10),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.25),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (note != null) {
      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _openNoteEditor(r, note, folderColor);
        },
        onLongPress: () => _showReminderActions(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              // Short colored accent dash
              Container(
                width: 3.5,
                height: 40,
                decoration: BoxDecoration(
                  color: folderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              // Icon badge for Note
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: folderColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.notes_rounded, color: folderColor, size: 20),
              ),
              const SizedBox(width: 12),
              // Note title and preview snippet
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      note.title,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (note.content.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        note.content.replaceAll('\n', ' '),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.35),
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Date
              Text(
                startTime.toString().substring(0, 10),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.25),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (checklist != null) {
      final totalItems = checklist.items.length;
      final completedItems = checklist.items.where((item) => item.done).length;
      final completionRatio = totalItems > 0
          ? completedItems / totalItems
          : 0.0;

      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _showChecklistDetails(r, checklist, folderColor);
        },
        onLongPress: () => _showReminderActions(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              // Short colored accent dash
              Container(
                width: 3.5,
                height: 40,
                decoration: BoxDecoration(
                  color: folderColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              // Icon badge for Checklist
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: folderColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.playlist_add_check_rounded,
                  color: folderColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              // Checklist title and progress
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            checklist.title,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$completedItems/$totalItems',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Progress bar
                    Container(
                      height: 4,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: completionRatio,
                        child: Container(
                          decoration: BoxDecoration(
                            color: folderColor,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Date
              Text(
                startTime.toString().substring(0, 10),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.25),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showNoteDetails(r, folderColor);
      },
      onLongPress: () => _showReminderActions(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            // Short colored accent dash
            Container(
              width: 3.5,
              height: 40,
              decoration: BoxDecoration(
                color: folderColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 14),
            // Icon badge
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: folderColor.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                timerDuration != null
                    ? Icons.alarm_rounded
                    : Icons.notes_rounded,
                color: folderColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // Note text
            Expanded(
              child: Text(
                _getDisplayText(r),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.5,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (r.attachmentPath != null) ...[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Image.file(File(r.attachmentPath!), fit: BoxFit.cover),
                ),
              ),
            ],
            const SizedBox(width: 16),
            if (timerDuration != null) ...[
              TimerCircularProgress(
                startTime: startTime,
                duration: timerDuration,
                color: folderColor,
                size: 14,
                strokeWidth: 2,
                interactive: false,
              ),
              const SizedBox(width: 12),
            ],
            // Date
            Text(
              startTime.toString().substring(0, 10),
              style: TextStyle(
                color: Colors.white.withOpacity(0.25),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCounterButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }

  Widget _buildPinnedCard(Reminder r, int index) {
    final timerDuration = _getReminderTimerDuration(r);
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      r.dateOfCreation.toInt() * 1000,
    );
    final folderColor = _getFolderColor(r.folder);
    final checklist = tryParseChecklist(r.context);
    final note = tryParseNote(r.context);
    final project = tryParseProject(r.context);
    final counter = tryParseCounter(r.context);

    if (counter != null) {
      return GestureDetector(
        onLongPress: () => _showReminderActions(r),
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: folderColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: folderColor.withOpacity(0.18), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        counter.title,
                        style: TextStyle(
                          color: folderColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.tag_rounded,
                      color: folderColor.withOpacity(0.8),
                      size: 16,
                    ),
                  ],
                ),
                const Spacer(),
                Center(
                  child: Text(
                    '${counter.value}',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: _buildCounterButton(
                        icon: Icons.remove_rounded,
                        color: folderColor,
                        onTap: () {
                          counter.value--;
                          updateReminderContext(
                            id: r.id!,
                            context: jsonEncode(counter.toJson()),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildCounterButton(
                        icon: Icons.add_rounded,
                        color: folderColor,
                        onTap: () {
                          counter.value++;
                          updateReminderContext(
                            id: r.id!,
                            context: jsonEncode(counter.toJson()),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (project != null) {
      final totalFolders = project.folders.length;
      final totalItems = project.folders.values.fold<int>(
        0,
        (sum, list) => sum + list.length,
      );
      final hasPhotos = project.folders.values.any(
        (list) => list.any((item) => item.photoPath != null),
      );

      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _openProjectCanvas(r, project);
        },
        onLongPress: () => _showReminderActions(r),
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: folderColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: folderColor.withOpacity(0.18), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      r.folder,
                      style: TextStyle(
                        color: folderColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Icon(
                      Icons.grid_view_rounded,
                      color: folderColor.withOpacity(0.8),
                      size: 16,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  project.name,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$totalFolders folders',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$totalItems total items',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 11,
                        ),
                      ),
                      if (hasPhotos) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.image_outlined,
                              size: 12,
                              color: folderColor.withOpacity(0.7),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Has photos',
                              style: TextStyle(
                                color: folderColor.withOpacity(0.7),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (note != null) {
      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _openNoteEditor(r, note, folderColor);
        },
        onLongPress: () => _showReminderActions(r),
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: folderColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: folderColor.withOpacity(0.18), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      r.folder,
                      style: TextStyle(
                        color: folderColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Icon(
                      Icons.description_rounded,
                      color: folderColor.withOpacity(0.8),
                      size: 16,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  note.title,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    note.content.isNotEmpty ? note.content : "Tap to write...",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (checklist != null) {
      final totalItems = checklist.items.length;
      final completedItems = checklist.items.where((item) => item.done).length;
      final completionRatio = totalItems > 0
          ? completedItems / totalItems
          : 0.0;

      return GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          _showChecklistDetails(r, checklist, folderColor);
        },
        onLongPress: () => _showReminderActions(r),
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: folderColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: folderColor.withOpacity(0.18), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      r.folder,
                      style: TextStyle(
                        color: folderColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Icon(
                      Icons.playlist_add_check_rounded,
                      color: folderColor.withOpacity(0.8),
                      size: 16,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  checklist.title,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                // Sleek progress bar
                Container(
                  height: 4,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: completionRatio,
                    child: Container(
                      decoration: BoxDecoration(
                        color: folderColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: checklist.items.take(2).map((item) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2.0),
                        child: Row(
                          children: [
                            Icon(
                              item.done
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 10,
                              color: item.done
                                  ? folderColor
                                  : Colors.white.withOpacity(0.3),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                item.text,
                                style: TextStyle(
                                  color: item.done
                                      ? Colors.white.withOpacity(0.3)
                                      : Colors.white.withOpacity(0.6),
                                  fontSize: 11,
                                  decoration: item.done
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showNoteDetails(r, folderColor);
      },
      onLongPress: () => _showReminderActions(r),
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: folderColor.withOpacity(0.06),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: folderColor.withOpacity(0.18), width: 1),
          image: r.attachmentPath != null
              ? DecorationImage(
                  image: FileImage(File(r.attachmentPath!)),
                  fit: BoxFit.cover,
                  colorFilter: ColorFilter.mode(
                    Colors.black.withOpacity(0.55),
                    BlendMode.darken,
                  ),
                )
              : null,
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        r.folder,
                        style: TextStyle(
                          color: folderColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                      if (timerDuration != null)
                        TimerCircularProgress(
                          startTime: startTime,
                          duration: timerDuration,
                          color: folderColor,
                          size: 10,
                          strokeWidth: 1.5,
                          interactive: false,
                        )
                      else if (r.attachmentPath != null)
                        Icon(
                          Icons.image_outlined,
                          color: folderColor,
                          size: 14,
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Text(
                      _getDisplayText(r),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w300,
                      ),
                      overflow: TextOverflow.fade,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TimerCircularProgress extends StatefulWidget {
  final DateTime startTime;
  final Duration duration;
  final Color color;
  final double size;
  final double strokeWidth;
  final VoidCallback? onTap;
  final bool interactive;

  const TimerCircularProgress({
    super.key,
    required this.startTime,
    required this.duration,
    required this.color,
    this.size = 24,
    this.strokeWidth = 3,
    this.onTap,
    this.interactive = true,
  });

  @override
  State<TimerCircularProgress> createState() => _TimerCircularProgressState();
}

class _TimerCircularProgressState extends State<TimerCircularProgress>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final endTime = widget.startTime.add(widget.duration);
    final remaining = endTime.difference(now);

    _controller = AnimationController(vsync: this, duration: widget.duration);

    if (remaining.isNegative) {
      _controller.value = 0.0;
    } else {
      _controller.value =
          remaining.inMilliseconds / widget.duration.inMilliseconds;
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(TimerCircularProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startTime != widget.startTime ||
        oldWidget.duration != widget.duration) {
      final now = DateTime.now();
      final endTime = widget.startTime.add(widget.duration);
      final remaining = endTime.difference(now);

      _controller.duration = widget.duration;
      if (remaining.isNegative) {
        _controller.value = 0.0;
        _controller.stop();
      } else {
        _controller.value =
            remaining.inMilliseconds / widget.duration.inMilliseconds;
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.value == 0.0) return const SizedBox.shrink();

        final progressIndicator = SizedBox(
          width: widget.size,
          height: widget.size,
          child: CircularProgressIndicator(
            value: _controller.value,
            strokeWidth: widget.strokeWidth,
            backgroundColor: widget.color.withOpacity(0.1),
            valueColor: AlwaysStoppedAnimation<Color>(widget.color),
          ),
        );

        if (!widget.interactive || widget.onTap == null) {
          return progressIndicator;
        }

        return GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onTap!();
          },
          child: progressIndicator,
        );
      },
    );
  }
}

class CheckboxItem {
  String text;
  bool done;

  CheckboxItem({required this.text, this.done = false});

  Map<String, dynamic> toJson() => {'text': text, 'done': done};

  factory CheckboxItem.fromJson(Map<String, dynamic> json) {
    return CheckboxItem(
      text: json['text'] as String? ?? '',
      done: json['done'] as bool? ?? false,
    );
  }
}

class ChecklistData {
  String title;
  List<CheckboxItem> items;

  ChecklistData({required this.title, required this.items});

  Map<String, dynamic> toJson() => {
    'type': 'list',
    'title': title,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory ChecklistData.fromJson(Map<String, dynamic> json) {
    final list = json['items'] as List?;
    final parsedItems = list != null
        ? list
              .map((e) => CheckboxItem.fromJson(e as Map<String, dynamic>))
              .toList()
        : <CheckboxItem>[];
    return ChecklistData(
      title: json['title'] as String? ?? 'List',
      items: parsedItems,
    );
  }
}

ChecklistData? tryParseChecklist(String text) {
  if (!text.trim().startsWith('{') || !text.trim().endsWith('}')) {
    return null;
  }
  try {
    final Map<String, dynamic> decoded =
        json.decode(text) as Map<String, dynamic>;
    if (decoded['type'] == 'list') {
      return ChecklistData.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}

class ChecklistBottomSheet extends StatefulWidget {
  final Reminder r;
  final ChecklistData checklist;
  final Color color;
  final Widget Function(String, {double fontSize}) buildTag;

  const ChecklistBottomSheet({
    super.key,
    required this.r,
    required this.checklist,
    required this.color,
    required this.buildTag,
  });

  @override
  State<ChecklistBottomSheet> createState() => _ChecklistBottomSheetState();
}

class _ChecklistBottomSheetState extends State<ChecklistBottomSheet> {
  late TextEditingController textController;
  late FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    textController = TextEditingController();
    focusNode = FocusNode();
  }

  @override
  void dispose() {
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startTime = DateTime.fromMillisecondsSinceEpoch(
      widget.r.dateOfCreation.toInt() * 1000,
    );
    final totalItems = widget.checklist.items.length;
    final completedItems = widget.checklist.items
        .where((item) => item.done)
        .length;
    final completionRatio = totalItems > 0 ? completedItems / totalItems : 0.0;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1B20),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                widget.buildTag(widget.r.folder, fontSize: 12),
                const Spacer(),
                Text(
                  startTime.toString().substring(0, 16),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.3),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              widget.checklist.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            // Progress text & bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '$completedItems of $totalItems completed',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                  ),
                ),
                Text(
                  '${(completionRatio * 100).toInt()}%',
                  style: TextStyle(
                    color: widget.color.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 4,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: completionRatio,
                child: Container(
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // List of items
            if (widget.checklist.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    'No items yet. Add one below!',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 14,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.checklist.items.length,
                itemBuilder: (context, index) {
                  final item = widget.checklist.items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        // satisfying circular checkbox
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            setState(() {
                              item.done = !item.done;
                            });
                            if (widget.r.id != null) {
                              updateReminderContext(
                                id: widget.r.id!,
                                context: jsonEncode(widget.checklist.toJson()),
                              );
                            }
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: item.done
                                  ? widget.color
                                  : Colors.transparent,
                              border: Border.all(
                                color: item.done
                                    ? widget.color
                                    : Colors.white.withOpacity(0.3),
                                width: 1.5,
                              ),
                            ),
                            child: item.done
                                ? const Icon(
                                    Icons.check,
                                    size: 14,
                                    color: Color(0xFF1D1B20),
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // item text
                        Expanded(
                          child: Text(
                            item.text,
                            style: TextStyle(
                              color: item.done
                                  ? Colors.white.withOpacity(0.3)
                                  : Colors.white.withOpacity(0.85),
                              fontSize: 15,
                              decoration: item.done
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                        ),
                        // delete button
                        IconButton(
                          icon: Icon(
                            Icons.close_rounded,
                            color: Colors.white.withOpacity(0.35),
                            size: 18,
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            setState(() {
                              widget.checklist.items.removeAt(index);
                            });
                            if (widget.r.id != null) {
                              updateReminderContext(
                                id: widget.r.id!,
                                context: jsonEncode(widget.checklist.toJson()),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  );
                },
              ),
            const SizedBox(height: 16),
            // Add new item input field
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF121318),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.add_rounded,
                    color: widget.color.withOpacity(0.7),
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: textController,
                      focusNode: focusNode,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: 'Add an item...',
                        hintStyle: TextStyle(
                          color: Colors.white.withOpacity(0.25),
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                      ),
                      onSubmitted: (val) {
                        final text = val.trim();
                        if (text.isNotEmpty) {
                          HapticFeedback.lightImpact();
                          setState(() {
                            widget.checklist.items.add(
                              CheckboxItem(text: text),
                            );
                          });
                          if (widget.r.id != null) {
                            updateReminderContext(
                              id: widget.r.id!,
                              context: jsonEncode(widget.checklist.toJson()),
                            );
                          }
                          textController.clear();
                          focusNode.requestFocus();
                        }
                      },
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      color: widget.color.withOpacity(0.9),
                      size: 20,
                    ),
                    onPressed: () {
                      final text = textController.text.trim();
                      if (text.isNotEmpty) {
                        HapticFeedback.lightImpact();
                        setState(() {
                          widget.checklist.items.add(CheckboxItem(text: text));
                        });
                        if (widget.r.id != null) {
                          updateReminderContext(
                            id: widget.r.id!,
                            context: jsonEncode(widget.checklist.toJson()),
                          );
                        }
                        textController.clear();
                        focusNode.requestFocus();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CommandTextEditingController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final textVal = text;
    if (textVal.startsWith('/') && textVal.isNotEmpty) {
      final spaceIndex = textVal.indexOf(' ');
      final cmd = spaceIndex == -1 ? textVal : textVal.substring(0, spaceIndex);

      final List<TextSpan> children = [];
      children.add(
        TextSpan(
          text: cmd,
          style: const TextStyle(
            color: Colors.greenAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      if (textVal.length > cmd.length) {
        children.add(
          TextSpan(text: textVal.substring(cmd.length), style: style),
        );
      }
      return TextSpan(style: style, children: children);
    }
    return super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
  }
}

class AlarmData {
  String text;
  AlarmData({required this.text});

  Map<String, dynamic> toJson() => {'type': 'alarm', 'text': text};

  factory AlarmData.fromJson(Map<String, dynamic> json) {
    return AlarmData(text: json['text'] as String? ?? '');
  }
}

AlarmData? tryParseAlarm(String contextText) {
  if (!contextText.trim().startsWith('{') ||
      !contextText.trim().endsWith('}')) {
    return null;
  }
  try {
    final Map<String, dynamic> decoded =
        json.decode(contextText) as Map<String, dynamic>;
    if (decoded['type'] == 'alarm') {
      return AlarmData.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}

class CounterData {
  String title;
  int value;

  CounterData({required this.title, required this.value});

  Map<String, dynamic> toJson() => {
    'type': 'counter',
    'title': title,
    'value': value,
  };

  factory CounterData.fromJson(Map<String, dynamic> json) {
    return CounterData(
      title: json['title'] as String? ?? 'Counter',
      value: json['value'] as int? ?? 0,
    );
  }
}

CounterData? tryParseCounter(String contextText) {
  if (!contextText.trim().startsWith('{') ||
      !contextText.trim().endsWith('}')) {
    return null;
  }
  try {
    final Map<String, dynamic> decoded =
        json.decode(contextText) as Map<String, dynamic>;
    if (decoded['type'] == 'counter') {
      return CounterData.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}
