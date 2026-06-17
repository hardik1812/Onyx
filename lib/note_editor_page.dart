import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fastreminder/src/rust/api/schema.dart';
import 'package:fastreminder/src/rust/api/simple.dart';

class NoteData {
  String title;
  String content;

  NoteData({required this.title, required this.content});

  Map<String, dynamic> toJson() => {
        'type': 'note',
        'title': title,
        'content': content,
      };

  factory NoteData.fromJson(Map<String, dynamic> json) {
    return NoteData(
      title: json['title'] as String? ?? 'Note',
      content: json['content'] as String? ?? '',
    );
  }
}

NoteData? tryParseNote(String contextText) {
  if (!contextText.trim().startsWith('{') || !contextText.trim().endsWith('}')) {
    return null;
  }
  try {
    final Map<String, dynamic> decoded = json.decode(contextText) as Map<String, dynamic>;
    if (decoded['type'] == 'note') {
      return NoteData.fromJson(decoded);
    }
  } catch (_) {}
  return null;
}

class NoteEditorPage extends StatefulWidget {
  final Reminder reminder;
  final NoteData initialNote;
  final Color color;

  const NoteEditorPage({
    super.key,
    required this.reminder,
    required this.initialNote,
    required this.color,
  });

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  Timer? _debounceTimer;
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialNote.title);
    _contentController = TextEditingController(text: widget.initialNote.content);

    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {
      _hasUnsavedChanges = true;
    });
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _saveNote);
  }

  void _saveNote() {
    if (!mounted || !_hasUnsavedChanges) return;

    setState(() {
      _isSaving = true;
    });

    final noteData = NoteData(
      title: _titleController.text.trim().isEmpty ? 'Untitled Note' : _titleController.text,
      content: _contentController.text,
    );

    if (widget.reminder.id != null) {
      try {
        updateReminderContext(
          id: widget.reminder.id!,
          context: jsonEncode(noteData.toJson()),
        );
        HapticFeedback.selectionClick();
      } catch (e) {
        debugPrint("Error auto-saving note: $e");
      }
    }

    if (mounted) {
      setState(() {
        _isSaving = false;
        _hasUnsavedChanges = false;
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    // Save any pending changes immediately on close
    if (_hasUnsavedChanges && widget.reminder.id != null) {
      final noteData = NoteData(
        title: _titleController.text.trim().isEmpty ? 'Untitled Note' : _titleController.text,
        content: _contentController.text,
      );
      updateReminderContext(
        id: widget.reminder.id!,
        context: jsonEncode(noteData.toJson()),
      );
    }
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121318),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () {
            HapticFeedback.lightImpact();
            // Force save and pop
            _debounceTimer?.cancel();
            if (_hasUnsavedChanges) {
              _saveNote();
            }
            Navigator.pop(context);
          },
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 20),
              child: AnimatedCrossFade(
                firstChild: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: widget.color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Saving',
                        style: TextStyle(
                          color: widget.color,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                secondChild: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_done_rounded,
                        color: widget.color,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Saved',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                crossFadeState: _isSaving ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                duration: const Duration(milliseconds: 200),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Note Title Input
              TextField(
                controller: _titleController,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
                cursorColor: widget.color,
                decoration: InputDecoration(
                  hintText: 'Title',
                  hintStyle: TextStyle(
                    color: Colors.white.withOpacity(0.2),
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                  border: InputBorder.none,
                ),
              ),
              const SizedBox(height: 16),
              // Endless scrolling content input
              Expanded(
                child: TextField(
                  controller: _contentController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.85),
                    fontSize: 16,
                    height: 1.6,
                  ),
                  cursorColor: widget.color,
                  decoration: InputDecoration(
                    hintText: 'Start typing your notes here...',
                    hintStyle: TextStyle(
                      color: Colors.white.withOpacity(0.15),
                      fontSize: 16,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
