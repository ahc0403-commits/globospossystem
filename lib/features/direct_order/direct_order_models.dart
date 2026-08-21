import 'dart:convert';

Never _invalidModel(String field) =>
    throw FormatException('DIRECT_ORDER_RESPONSE_INVALID:$field');

void _expectKeys(Map<String, dynamic> json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) _invalidModel('unknown:${unknown.first}');
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) _invalidModel(key);
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) _invalidModel(key);
  return value;
}

num _requiredNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) _invalidModel(key);
  return value;
}

double? _optionalDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite) _invalidModel(key);
  return value.toDouble();
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) _invalidModel(key);
  return value;
}

DateTime _requiredDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) _invalidModel(key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) _invalidModel(key);
  return parsed;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) _invalidModel(key);
  return Map<String, dynamic>.from(value);
}

List<dynamic> _requiredList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) _invalidModel(key);
  return value;
}

class DirectOrderBank {
  const DirectOrderBank({
    required this.bin,
    required this.accountNumber,
    required this.accountHolder,
    required this.label,
  });

  final String bin;
  final String accountNumber;
  final String accountHolder;
  final String label;

  factory DirectOrderBank.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'bin',
      'account_number',
      'account_holder',
      'label',
    });
    return DirectOrderBank(
      bin: _requiredString(json, 'bin'),
      accountNumber: _requiredString(json, 'account_number'),
      accountHolder: _requiredString(json, 'account_holder'),
      label: _optionalString(json, 'label') ?? '',
    );
  }
}

class DirectOrderCategory {
  const DirectOrderCategory({
    required this.id,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.sortOrder,
  });

  final String id;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int sortOrder;

  factory DirectOrderCategory.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'name_ko',
      'name_vi',
      'name_en',
      'sort_order',
    });
    return DirectOrderCategory(
      id: _requiredString(json, 'id'),
      nameKo: _requiredString(json, 'name_ko'),
      nameVi: _requiredString(json, 'name_vi'),
      nameEn: _requiredString(json, 'name_en'),
      sortOrder: _requiredNumber(json, 'sort_order').toInt(),
    );
  }

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo,
    'en' => nameEn,
    _ => nameVi,
  };
}

class DirectOrderMenuItem {
  const DirectOrderMenuItem({
    required this.id,
    required this.categoryId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.vatCategory,
    required this.sortOrder,
  });

  final String id;
  final String categoryId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final String? description;
  final double price;
  final String? imageUrl;
  final String vatCategory;
  final int sortOrder;

  factory DirectOrderMenuItem.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'category_id',
      'name_ko',
      'name_vi',
      'name_en',
      'description',
      'price',
      'image_url',
      'vat_category',
      'sort_order',
    });
    return DirectOrderMenuItem(
      id: _requiredString(json, 'id'),
      categoryId: _requiredString(json, 'category_id'),
      nameKo: _requiredString(json, 'name_ko'),
      nameVi: _requiredString(json, 'name_vi'),
      nameEn: _requiredString(json, 'name_en'),
      description: _optionalString(json, 'description'),
      price: _requiredNumber(json, 'price').toDouble(),
      imageUrl: _optionalString(json, 'image_url'),
      vatCategory: _requiredString(json, 'vat_category'),
      sortOrder: _requiredNumber(json, 'sort_order').toInt(),
    );
  }

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo,
    'en' => nameEn,
    _ => nameVi,
  };
}

class DirectOrderStorefront {
  const DirectOrderStorefront({
    required this.storeId,
    required this.storeName,
    required this.slug,
    required this.paused,
    required this.minimumOrderAmount,
    required this.defaultLatitude,
    required this.defaultLongitude,
    required this.googleMapsBrowserKey,
    required this.bank,
    required this.categories,
    required this.items,
  });

  final String storeId;
  final String storeName;
  final String slug;
  final bool paused;
  final double minimumOrderAmount;
  final double? defaultLatitude;
  final double? defaultLongitude;
  final String? googleMapsBrowserKey;
  final DirectOrderBank bank;
  final List<DirectOrderCategory> categories;
  final List<DirectOrderMenuItem> items;

  factory DirectOrderStorefront.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'store_id',
      'store_name',
      'slug',
      'paused',
      'ordering_starts_at',
      'ordering_cutoff_at',
      'minimum_order_amount',
      'default_latitude',
      'default_longitude',
      'google_maps_browser_key',
      'bank',
      'categories',
      'items',
    });
    _requiredString(json, 'ordering_starts_at');
    _requiredString(json, 'ordering_cutoff_at');
    final categoryRaw = _requiredList(json, 'categories');
    final itemsRaw = _requiredList(json, 'items');
    return DirectOrderStorefront(
      storeId: _requiredString(json, 'store_id'),
      storeName: _requiredString(json, 'store_name'),
      slug: _requiredString(json, 'slug'),
      paused: _requiredBool(json, 'paused'),
      minimumOrderAmount: _requiredNumber(
        json,
        'minimum_order_amount',
      ).toDouble(),
      defaultLatitude: _optionalDouble(json, 'default_latitude'),
      defaultLongitude: _optionalDouble(json, 'default_longitude'),
      googleMapsBrowserKey: _optionalString(json, 'google_maps_browser_key'),
      bank: DirectOrderBank.fromJson(_requiredMap(json, 'bank')),
      categories: categoryRaw
          .map((row) {
            if (row is! Map) _invalidModel('categories');
            return DirectOrderCategory.fromJson(Map<String, dynamic>.from(row));
          })
          .toList(growable: false),
      items: itemsRaw
          .map((row) {
            if (row is! Map) _invalidModel('items');
            return DirectOrderMenuItem.fromJson(Map<String, dynamic>.from(row));
          })
          .toList(growable: false),
    );
  }
}

class DirectOrderSession {
  const DirectOrderSession({
    required this.id,
    required this.secret,
    required this.expiresAt,
  });

  final String id;
  final String secret;
  final DateTime expiresAt;

  bool get isValid =>
      id.isNotEmpty &&
      secret.isNotEmpty &&
      expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)));

  Map<String, dynamic> toJson() => {
    'id': id,
    'secret': secret,
    'expires_at': expiresAt.toIso8601String(),
  };

  factory DirectOrderSession.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'session_id',
      'id',
      'store_id',
      'secret',
      'expires_at',
    });
    final rawId = json['session_id'] ?? json['id'];
    if (rawId is! String || rawId.trim().isEmpty) {
      _invalidModel('session_id');
    }
    if (json.containsKey('store_id')) _requiredString(json, 'store_id');
    return DirectOrderSession(
      id: rawId,
      secret: _requiredString(json, 'secret'),
      expiresAt: _requiredDateTime(json, 'expires_at'),
    );
  }
}

class DirectOrderAddress {
  const DirectOrderAddress({
    required this.customerName,
    required this.customerPhone,
    required this.formattedAddress,
    required this.detailAddress,
    required this.latitude,
    required this.longitude,
    required this.addressSource,
    required this.locationVerified,
    this.googlePlaceId,
    this.district,
    this.ward,
  });

  final String customerName;
  final String customerPhone;
  final String formattedAddress;
  final String detailAddress;
  final double latitude;
  final double longitude;
  final String? googlePlaceId;
  final String? district;
  final String? ward;
  final String addressSource;
  final bool locationVerified;

  Map<String, dynamic> toJson() => {
    'customer_name': customerName,
    'customer_phone': customerPhone,
    'formatted_address': formattedAddress,
    'detail_address': detailAddress,
    'latitude': latitude,
    'longitude': longitude,
    'google_place_id': googlePlaceId,
    'district': district,
    'ward': ward,
    'address_source': addressSource,
    'location_verified': locationVerified,
  };

  String encode() => jsonEncode(toJson());

  factory DirectOrderAddress.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'customer_name',
      'customer_phone',
      'formatted_address',
      'detail_address',
      'latitude',
      'longitude',
      'google_place_id',
      'district',
      'ward',
      'address_source',
      'location_verified',
    });
    return DirectOrderAddress(
      customerName: _requiredString(json, 'customer_name'),
      customerPhone: _requiredString(json, 'customer_phone'),
      formattedAddress: _requiredString(json, 'formatted_address'),
      detailAddress: _requiredString(json, 'detail_address'),
      latitude: _requiredNumber(json, 'latitude').toDouble(),
      longitude: _requiredNumber(json, 'longitude').toDouble(),
      googlePlaceId: _optionalString(json, 'google_place_id'),
      district: _optionalString(json, 'district'),
      ward: _optionalString(json, 'ward'),
      addressSource: _requiredString(json, 'address_source'),
      locationVerified: _requiredBool(json, 'location_verified'),
    );
  }

  factory DirectOrderAddress.decode(String raw) {
    return DirectOrderAddress.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }
}

class DirectOrderPlaceSuggestion {
  const DirectOrderPlaceSuggestion({required this.placeId, required this.text});
  final String placeId;
  final String text;

  factory DirectOrderPlaceSuggestion.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'place_id', 'text'});
    return DirectOrderPlaceSuggestion(
      placeId: _requiredString(json, 'place_id'),
      text: _requiredString(json, 'text'),
    );
  }
}

class DirectOrderPlace {
  const DirectOrderPlace({
    required this.formattedAddress,
    required this.latitude,
    required this.longitude,
    this.placeId,
    this.district,
    this.ward,
  });

  final String formattedAddress;
  final double latitude;
  final double longitude;
  final String? placeId;
  final String? district;
  final String? ward;

  factory DirectOrderPlace.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'place_id',
      'formatted_address',
      'latitude',
      'longitude',
      'district',
      'ward',
    });
    final latitude = _requiredNumber(json, 'latitude').toDouble();
    final longitude = _requiredNumber(json, 'longitude').toDouble();
    if (latitude < -90 || latitude > 90) _invalidModel('latitude');
    if (longitude < -180 || longitude > 180) _invalidModel('longitude');
    return DirectOrderPlace(
      formattedAddress: _requiredString(json, 'formatted_address'),
      latitude: latitude,
      longitude: longitude,
      placeId: _optionalString(json, 'place_id'),
      district: _optionalString(json, 'district'),
      ward: _optionalString(json, 'ward'),
    );
  }
}

class DirectOrderQuote {
  const DirectOrderQuote({
    required this.id,
    required this.menuTotal,
    required this.serviceChargeTotal,
    required this.deliveryFeeTotal,
    required this.finalTotal,
    required this.status,
    required this.expiresAt,
  });

  final String id;
  final double menuTotal;
  final double serviceChargeTotal;
  final double deliveryFeeTotal;
  final double finalTotal;
  final String status;
  final DateTime? expiresAt;

  factory DirectOrderQuote.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'version',
      'menu_total',
      'service_charge_total',
      'delivery_fee_total',
      'final_total',
      'status',
      'expires_at',
    });
    _requiredNumber(json, 'version');
    return DirectOrderQuote(
      id: _requiredString(json, 'id'),
      menuTotal: _requiredNumber(json, 'menu_total').toDouble(),
      serviceChargeTotal: _requiredNumber(
        json,
        'service_charge_total',
      ).toDouble(),
      deliveryFeeTotal: _requiredNumber(json, 'delivery_fee_total').toDouble(),
      finalTotal: _requiredNumber(json, 'final_total').toDouble(),
      status: _requiredString(json, 'status'),
      expiresAt: _requiredDateTime(json, 'expires_at'),
    );
  }
}

class DirectOrderMessage {
  const DirectOrderMessage({
    required this.id,
    required this.senderType,
    required this.messageType,
    required this.body,
    required this.hasAttachment,
    required this.createdAt,
  });

  final String id;
  final String senderType;
  final String messageType;
  final String? body;
  final bool hasAttachment;
  final DateTime createdAt;

  factory DirectOrderMessage.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'id',
      'sender_type',
      'message_type',
      'body',
      'has_attachment',
      'created_at',
    });
    return DirectOrderMessage(
      id: _requiredString(json, 'id'),
      senderType: _requiredString(json, 'sender_type'),
      messageType: _requiredString(json, 'message_type'),
      body: _optionalString(json, 'body'),
      hasAttachment: _requiredBool(json, 'has_attachment'),
      createdAt: _requiredDateTime(json, 'created_at'),
    );
  }
}

class DirectOrderStatus {
  const DirectOrderStatus({
    required this.requestId,
    required this.referenceCode,
    required this.state,
    required this.messages,
    this.quote,
    this.fulfillmentStatus,
    this.grabTrackingUrl,
  });

  final String requestId;
  final String referenceCode;
  final String state;
  final DirectOrderQuote? quote;
  final List<DirectOrderMessage> messages;
  final String? fulfillmentStatus;
  final String? grabTrackingUrl;

  factory DirectOrderStatus.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {
      'request_id',
      'store_id',
      'reference_code',
      'state',
      'created_at',
      'items',
      'quote',
      'messages',
      'fulfillment',
      'dispatch',
    });
    final quoteRaw = json['quote'];
    if (quoteRaw != null && quoteRaw is! Map) _invalidModel('quote');
    final messagesRaw = _requiredList(json, 'messages');
    final fulfillmentRaw = json['fulfillment'];
    if (fulfillmentRaw != null && fulfillmentRaw is! Map) {
      _invalidModel('fulfillment');
    }
    final dispatchRaw = json['dispatch'];
    if (dispatchRaw != null && dispatchRaw is! Map) {
      _invalidModel('dispatch');
    }
    _requiredString(json, 'store_id');
    _requiredDateTime(json, 'created_at');
    for (final row in _requiredList(json, 'items')) {
      if (row is! Map) _invalidModel('items');
      final item = Map<String, dynamic>.from(row);
      _expectKeys(item, const {
        'menu_item_id',
        'name_ko',
        'name_vi',
        'name_en',
        'unit_price',
        'quantity',
        'note',
      });
      _requiredString(item, 'menu_item_id');
      _requiredString(item, 'name_ko');
      _requiredString(item, 'name_vi');
      _requiredString(item, 'name_en');
      _requiredNumber(item, 'unit_price');
      _requiredNumber(item, 'quantity');
      _optionalString(item, 'note');
    }
    if (fulfillmentRaw is Map) {
      final fulfillment = Map<String, dynamic>.from(fulfillmentRaw);
      _expectKeys(fulfillment, const {'status', 'pickup_code', 'updated_at'});
      _requiredString(fulfillment, 'status');
      _requiredString(fulfillment, 'pickup_code');
      _requiredDateTime(fulfillment, 'updated_at');
    }
    if (dispatchRaw is Map) {
      final dispatch = Map<String, dynamic>.from(dispatchRaw);
      _expectKeys(dispatch, const {'grab_tracking_url', 'sent_at'});
      _requiredString(dispatch, 'grab_tracking_url');
      _requiredDateTime(dispatch, 'sent_at');
    }
    return DirectOrderStatus(
      requestId: _requiredString(json, 'request_id'),
      referenceCode: _requiredString(json, 'reference_code'),
      state: _requiredString(json, 'state'),
      quote: quoteRaw is Map
          ? DirectOrderQuote.fromJson(Map<String, dynamic>.from(quoteRaw))
          : null,
      messages: messagesRaw
          .map((row) {
            if (row is! Map) _invalidModel('messages');
            return DirectOrderMessage.fromJson(Map<String, dynamic>.from(row));
          })
          .toList(growable: false),
      fulfillmentStatus: fulfillmentRaw is Map
          ? fulfillmentRaw['status']?.toString()
          : null,
      grabTrackingUrl: dispatchRaw is Map
          ? dispatchRaw['grab_tracking_url']?.toString()
          : null,
    );
  }
}
