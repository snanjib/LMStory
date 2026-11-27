import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Localizes a built-in attribute or a relationship with a named entity.
/// A null result lets callers display a custom or unrecognized key verbatim.
String? factualAttributeLabel(
  Translations t,
  FactualEntityType? type,
  String attrKey,
) {
  final labels = t.intermediate.memoryBrowser.attributeLabels;
  final objectName = AttributeSchema.relationshipObjectOf(attrKey);
  if (objectName != null) return labels.relationshipWith(name: objectName);
  if (type == null || !AttributeSchema.isBuiltInAttrKey(type, attrKey)) {
    return null;
  }

  return switch (attrKey) {
    'name' => switch (type) {
        FactualEntityType.character => labels.characterName,
        FactualEntityType.location => labels.locationName,
        FactualEntityType.item => labels.itemName,
        FactualEntityType.lore => labels.loreName,
        FactualEntityType.organization => labels.organizationName,
        FactualEntityType.misc => labels.name,
      },
    'description' => switch (type) {
        FactualEntityType.lore => labels.loreDescription,
        FactualEntityType.organization => labels.organizationDescription,
        _ => labels.description,
      },
    'personality' => labels.personality,
    'background' => labels.background,
    'relationships' => labels.relationships,
    'skills' => labels.skills,
    'features' => labels.features,
    'owner' => labels.owner,
    'category' => labels.category,
    'leader' => labels.leader,
    'members' => labels.members,
    _ => null,
  };
}
