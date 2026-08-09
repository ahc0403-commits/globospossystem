String displayFloorLabel(String storedLabel) {
  return switch (storedLabel.trim().toUpperCase()) {
    '1F' => 'G',
    '2F' => '1F',
    '3F' => '2F',
    final label => label,
  };
}

String storedFloorLabel(String displayLabel) {
  return switch (displayLabel.trim().toUpperCase()) {
    'G' => '1F',
    '1F' => '2F',
    '2F' => '3F',
    final label => label,
  };
}
