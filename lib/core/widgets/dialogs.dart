import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../system/command_runner.dart';
import '../system/privilege.dart';

/// Shows a confirmation dialog. Resolves to `true` only when confirmed.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
  IconData? icon,
  String? requireCheckbox,
}) async {
  final bool? result = await M3EDialog.show<bool>(
    context,
    dialog: _ConfirmDialog(
      title: title,
      message: message,
      content: content,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
      icon: icon,
      requireCheckbox: requireCheckbox,
    ),
  );
  return result ?? false;
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.content,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
    required this.icon,
    required this.requireCheckbox,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final IconData? icon;
  final String? requireCheckbox;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool canConfirm = widget.requireCheckbox == null || _acknowledged;
    return M3EDialog(
      title: widget.title,
      icon: widget.icon == null ? null : Icon(widget.icon, color: widget.destructive ? scheme.error : scheme.secondary),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (widget.message != null) Text(widget.message!),
          if (widget.message != null && widget.content != null) const SizedBox(height: 12),
          ?widget.content,
          if (widget.requireCheckbox != null) ...<Widget>[
            const SizedBox(height: 12),
            M3ECheckbox(
              value: _acknowledged,
              label: Text(widget.requireCheckbox!),
              onChanged: (bool? v) => setState(() => _acknowledged = v ?? false),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        M3EButton.text(onPressed: () => Navigator.of(context).pop(false), child: Text(widget.cancelLabel)),
        M3EButton(
          style: widget.destructive ? M3EButtonStyle.filled : M3EButtonStyle.tonal,
          enabled: canConfirm,
          onPressed: canConfirm ? () => Navigator.of(context).pop(true) : null,
          decoration: widget.destructive ? destructiveButtonDecoration(scheme) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Error-coloured filled button styling for destructive actions.
M3EButtonDecoration destructiveButtonDecoration(ColorScheme scheme) {
  return M3EButtonDecoration(
    backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      return states.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.12) : scheme.error;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      return states.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.38) : scheme.onError;
    }),
  );
}

/// Simple informational dialog with a single close button.
Future<void> showInfoDialog(BuildContext context, {required String title, required String message, IconData? icon}) {
  return M3EDialog.show<void>(
    context,
    dialog: Builder(
      builder: (BuildContext context) => M3EDialog(
        title: title,
        icon: icon == null ? null : Icon(icon),
        content: SelectableText(message),
        actions: <Widget>[M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    ),
  );
}

/// Asks for a single line of text. Returns null when cancelled.
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initialValue = '',
  String confirmLabel = 'OK',
  String? supportingText,
  String? Function(String value)? validator,
}) {
  return M3EDialog.show<String>(
    context,
    dialog: _TextInputDialog(
      title: title,
      label: label,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      supportingText: supportingText,
      validator: validator,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.label,
    required this.initialValue,
    required this.confirmLabel,
    required this.supportingText,
    required this.validator,
  });

  final String title;
  final String label;
  final String initialValue;
  final String confirmLabel;
  final String? supportingText;
  final String? Function(String value)? validator;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    final String? error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return M3EDialog(
      title: widget.title,
      content: SizedBox(
        width: 420,
        child: M3ETextField(
          controller: _controller,
          label: widget.label,
          autofocus: true,
          supportingText: widget.supportingText,
          errorText: _error,
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: <Widget>[
        M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        M3EButton.tonal(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// In-app sudo password prompt used by [PrivilegeService].
Future<String?> showPasswordDialog(BuildContext context, {required String reason, String? error}) {
  return M3EDialog.show<String>(
    context,
    barrierDismissible: false,
    dialog: _PasswordDialog(reason: reason, error: error),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.reason, required this.error});

  final String reason;
  final String? error;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text;
    if (value.isEmpty) return;
    _controller.clear();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return M3EDialog(
      title: 'Administrator rights needed',
      icon: const Icon(M3EIcons.admin_panel_settings),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.reason, style: text.bodyMedium),
            const SizedBox(height: 8),
            Text(
              'Enter your password to continue with sudo. It is sent only to sudo '
              'and is never stored.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            M3ETextField(
              controller: _controller,
              label: 'Password',
              variant: M3ETextFieldVariant.outlined,
              obscureText: true,
              showPasswordToggle: true,
              autofocus: true,
              errorText: widget.error,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        M3EButton.text(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        M3EButton.filled(onPressed: _submit, child: const Text('Authenticate')),
      ],
    );
  }
}

/// A unit of work whose output is streamed into [CommandLogDialog].
typedef LoggedTask = Future<CommandResult> Function(void Function(String line) log);

/// Runs [task] while showing its live output. Handles authentication
/// cancellation and errors, and returns the final result (or null if it
/// never ran, e.g. the user cancelled authentication).
Future<CommandResult?> runWithLog(
  BuildContext context, {
  required String title,
  required LoggedTask task,
  String? successMessage,
}) {
  return M3EDialog.show<CommandResult>(
    context,
    barrierDismissible: false,
    dialog: CommandLogDialog(title: title, task: task, successMessage: successMessage),
  );
}

class CommandLogDialog extends StatefulWidget {
  const CommandLogDialog({super.key, required this.title, required this.task, this.successMessage});

  final String title;
  final LoggedTask task;
  final String? successMessage;

  @override
  State<CommandLogDialog> createState() => _CommandLogDialogState();
}

class _CommandLogDialogState extends State<CommandLogDialog> {
  static const int _maxLines = 2000;

  final List<String> _lines = <String>[];
  final ScrollController _scroll = ScrollController();
  CommandResult? _result;
  String? _failure;
  bool _running = true;
  bool _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _log(String line) {
    if (!mounted) return;
    setState(() {
      _lines.add(line);
      if (_lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
    });
    if (!_scrollScheduled) {
      _scrollScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollScheduled = false;
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _start() async {
    CommandResult? result;
    String? failure;
    try {
      result = await widget.task(_log);
      if (!result.ok) {
        failure = result.errorSummary;
      }
    } on PrivilegeCancelled {
      failure = 'Authentication was cancelled. Nothing was changed.';
    } on PrivilegeUnavailable catch (e) {
      failure = e.message;
    } on Object catch (e) {
      failure = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final Widget status;
    if (_running) {
      status = Row(
        children: <Widget>[
          const M3ELoadingIndicator(size: 32),
          const SizedBox(width: 12),
          Expanded(child: Text('Working…', style: text.bodyMedium)),
        ],
      );
    } else if (_failure == null) {
      status = Row(
        children: <Widget>[
          Icon(M3EIcons.check_circle, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(widget.successMessage ?? 'Done', style: text.bodyMedium)),
        ],
      );
    } else {
      status = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(M3EIcons.error_outline, color: scheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(_failure!, style: text.bodyMedium?.copyWith(color: scheme.error)),
          ),
        ],
      );
    }

    return M3EDialog(
      title: widget.title,
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            status,
            const SizedBox(height: 16),
            Container(
              height: 260,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
              padding: const EdgeInsets.all(12),
              child: _lines.isEmpty
                  ? Center(
                      child: Text(
                        _running ? 'Waiting for output…' : 'No output',
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: _lines.length,
                        itemBuilder: (BuildContext context, int i) =>
                            Text(_lines[i], style: text.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.35)),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        M3EButton.tonal(
          onPressed: _running ? null : () => Navigator.of(context).pop(_result),
          enabled: !_running,
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Shows a short message at the bottom of the window.
void showSnack(BuildContext context, String message) {
  M3ESnackbar.show(context, message: message);
}
