/// Retired integrations require a new product decision before reactivation.
class IntegrationAvailability {
  static bool get deliberryRetired => true;
}

const deliberryRetiredError = 'DELIBERRY_INTEGRATION_RETIRED';
