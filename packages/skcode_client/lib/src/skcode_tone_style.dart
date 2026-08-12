import "package:flutter/material.dart";

import "skcode_activity_taxonomy.dart";

/// The color an [ActivityTone] renders as, so a human scanning the
/// transcript can tell read/write/admin/neutral apart at a glance without
/// reading a single word (spec section 6: "the whole point is scanning
/// blast radius"). Theme-aware except [ActivityTone.write], which the shell
/// layout spec (section 7.1) pins to a literal amber ("write-tone (amber)
/// left border") so the same color means "write" in the inject composer AND
/// here.
Color skcodeToneColor(BuildContext context, ActivityTone tone) {
  final scheme = Theme.of(context).colorScheme;
  switch (tone) {
    case ActivityTone.read:
      return scheme.primary;
    case ActivityTone.write:
      return Colors.amber;
    case ActivityTone.admin:
      return scheme.error;
    case ActivityTone.neutral:
      return scheme.onSurfaceVariant;
  }
}

/// Short label for a tone, used as an a11y/tooltip string next to the color
/// (color alone is never the only signal).
String skcodeToneLabel(ActivityTone tone) {
  switch (tone) {
    case ActivityTone.read:
      return "read";
    case ActivityTone.write:
      return "write";
    case ActivityTone.admin:
      return "admin";
    case ActivityTone.neutral:
      return "neutral";
  }
}

/// A short human label for a render class, used when [ActivityClassification.label]
/// is null (the mapping table only names an override label for the "Launched
/// agent" and "Ran tool" rows; every other class gets this generic one).
String skcodeRenderClassLabel(ActivityRenderClass renderClass) {
  switch (renderClass) {
    case ActivityRenderClass.message:
      return "Message";
    case ActivityRenderClass.fileEdit:
      return "Edit";
    case ActivityRenderClass.fileRead:
      return "Read";
    case ActivityRenderClass.skillRead:
      return "Skill";
    case ActivityRenderClass.shell:
      return "Shell";
    case ActivityRenderClass.mcpOp:
      return "MCP";
    case ActivityRenderClass.status:
      return "Status";
    case ActivityRenderClass.thought:
      return "Thought";
    case ActivityRenderClass.plan:
      return "Plan";
    case ActivityRenderClass.permission:
      return "Permission";
    case ActivityRenderClass.diff:
      return "Diff";
    case ActivityRenderClass.image:
      return "Image";
    case ActivityRenderClass.error:
      return "Error";
    case ActivityRenderClass.generic:
      return "Activity";
    case ActivityRenderClass.raw:
      return "Raw";
    case ActivityRenderClass.suppressed:
      return "Suppressed";
  }
}
