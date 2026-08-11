enum FulfillmentMode {
  posPrint('pos_print'),
  paperless('paperless');

  const FulfillmentMode(this.dbValue);

  final String dbValue;

  bool get isPaperless => this == FulfillmentMode.paperless;

  static FulfillmentMode fromValue(Object? value) =>
      value?.toString() == paperless.dbValue ? paperless : posPrint;
}
