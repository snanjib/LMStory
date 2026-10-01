import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_card.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_data.dart';

/// Wiki 条目视图：可点击卡片进入对应 wiki 子页。
class WikiEntryView extends StatelessWidget {
  const WikiEntryView({required this.entry, super.key});

  final WikiEntry entry;

  @override
  Widget build(BuildContext context) {
    return SimpleSettingCard(
      icon: entry.icon,
      title: entry.title,
      subtitle: entry.subtitle,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: entry.pageBuilder),
      ),
    );
  }
}
