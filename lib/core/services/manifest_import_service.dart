import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

enum MarketplaceFormat { shopee, mercadoLivre, amazon, generic }

extension MarketplaceFormatLabel on MarketplaceFormat {
  String get label {
    switch (this) {
      case MarketplaceFormat.shopee:
        return 'Shopee';
      case MarketplaceFormat.mercadoLivre:
        return 'Mercado Livre';
      case MarketplaceFormat.amazon:
        return 'Amazon';
      case MarketplaceFormat.generic:
        return 'Planilha';
    }
  }
}

class ImportedItem {
  final String barcodeBase;
  final String description;
  final int quantity;
  final double weightKg;

  const ImportedItem({
    required this.barcodeBase,
    required this.description,
    required this.quantity,
    required this.weightKg,
  });
}

class ImportedStop {
  final String orderRef;
  final String recipient;
  final String addressQuery;
  final String displayAddress;
  final double? latitude;
  final double? longitude;
  final String? notes;
  final List<ImportedItem> items;

  const ImportedStop({
    required this.orderRef,
    required this.recipient,
    required this.addressQuery,
    required this.displayAddress,
    this.latitude,
    this.longitude,
    this.notes,
    required this.items,
  });

  bool get hasCoords => latitude != null && longitude != null;

  int get totalUnits => items.fold(0, (acc, i) => acc + i.quantity);
}

class ResolvedImportItem {
  final String barcode;
  final String description;
  final double weightKg;

  const ResolvedImportItem({
    required this.barcode,
    required this.description,
    required this.weightKg,
  });
}

class ResolvedImportStop {
  final String orderRef;
  final String recipient;
  final String address;
  final double latitude;
  final double longitude;
  final String? notes;
  final List<ResolvedImportItem> items;

  const ResolvedImportStop({
    required this.orderRef,
    required this.recipient,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.notes,
    required this.items,
  });
}

class ImportParseResult {
  final MarketplaceFormat detectedFormat;
  final List<ImportedStop> stops;
  final int skippedCancelled;
  final int rowsWithoutAddress;

  const ImportParseResult({
    required this.detectedFormat,
    required this.stops,
    required this.skippedCancelled,
    required this.rowsWithoutAddress,
  });

  int get totalUnits => stops.fold(0, (acc, s) => acc + s.totalUnits);
}

class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

class ManifestImportService {
  static const int maxBytes = 10 * 1024 * 1024;

  Future<List<List<String>>> readRows(String fileName, List<int> bytes) async {
    if (bytes.length > maxBytes) {
      throw const ImportException('Arquivo maior que 10 MB.');
    }
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'csv':
      case 'txt':
        return _readDelimited(bytes);
      case 'xls':
      case 'xlsx':
        return _readExcel(bytes);
      default:
        throw ImportException(
          'Tipo .$ext não suportado. Use CSV, TXT, XLS ou XLSX.',
        );
    }
  }

  List<List<String>> _readDelimited(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      text = latin1.decode(bytes);
    }
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final sample = text.split('\n').where((l) => l.trim().isNotEmpty).take(5).join('\n');

    String delimiter = ',';
    int best = -1;
    for (final d in [';', ',', '\t', '|']) {
      final count = sample.split(d).length;
      if (count > best) {
        best = count;
        delimiter = d;
      }
    }

    final converter = Csv(fieldDelimiter: delimiter, autoDetect: false);
    final raw = converter.decode(text);
    return raw
        .map((row) => row.map((c) => c.toString().trim()).toList())
        .where((row) => row.any((c) => c.isNotEmpty))
        .toList();
  }

  List<List<String>> _readExcel(List<int> bytes) {
    final excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) {
      throw const ImportException('Planilha sem abas.');
    }
    final table = excel.tables.values.firstWhere(
      (t) => t.rows.any((r) => r.any((c) => _cellText(c).isNotEmpty)),
      orElse: () => excel.tables.values.first,
    );
    final rows = table.rows
        .map((row) => row.map(_cellText).toList())
        .where((row) => row.any((c) => c.isNotEmpty))
        .toList();
    if (rows.isEmpty) {
      throw const ImportException('Planilha vazia.');
    }
    return rows;
  }

  static String _cellText(Data? cell) {
    final v = cell?.value;
    if (v == null) return '';
    if (v is IntCellValue) return v.value.toString();
    if (v is DoubleCellValue) {
      final d = v.value;
      return d == d.truncateToDouble() ? d.toInt().toString() : d.toString();
    }
    if (v is TextCellValue) return (v.value.text ?? '').trim();
    if (v is BoolCellValue) return v.value.toString();
    return v.toString().trim();
  }

  static String normalizeHeader(String header) {
    var s = header.toLowerCase().trim();
    const accents = {
      'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'ñ': 'n',
    };
    accents.forEach((k, v) => s = s.replaceAll(k, v));
    return s.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static const _amazonKeys = {
    'shipaddress1', 'shipcity', 'shipstate', 'shippostalcode',
    'recipientname', 'quantitypurchased', 'orderitemid', 'orderid',
  };
  static const _shopeeKeys = {
    'skureferenceno', 'variationname', 'usernamebuyer', 'orderid',
    'grandtotal', 'dealprice',
  };

  static MarketplaceFormat detectFormat(List<String> header) {
    final norm = header.map(normalizeHeader).toSet();
    final amazonHits = _amazonKeys.where(norm.contains).length;
    if (amazonHits >= 3) return MarketplaceFormat.amazon;
    final shopeeHits = _shopeeKeys.where(norm.contains).length;
    if (shopeeHits >= 2 &&
        (norm.contains('usernamebuyer') ||
            norm.contains('skureferenceno') ||
            norm.contains('variationname'))) {
      return MarketplaceFormat.shopee;
    }
    return MarketplaceFormat.generic;
  }

  static const _orderAliases = {
    'orderid', 'ordernumber', 'merchantorderid', 'amazonorderid',
    'numerodopedido', 'numeropedido', 'npedido', 'iddopedido',
    'pedidonumero', 'numerooperacao', 'numerodavenda', 'idvenda', 'order',
  };
  static const _recipientAliases = {
    'recipientname', 'buyername', 'buyerusername', 'usernamebuyer',
    'nomedestinatario', 'destinatario', 'nomecomprador', 'comprador',
    'customername', 'customer', 'clientname', 'nomecliente', 'cliente',
    'recipient', 'buyer', 'nomedocliente', 'shipname',
  };
  static const _addr1Aliases = {
    'shipaddress1', 'address1', 'addressfieldone', 'endereco',
    'logradouro', 'rua', 'street', 'shipaddress', 'address',
    'enderecodeentrega', 'shippingaddress', 'deliveryaddress',
    'destinationaddress',
  };
  static const _addrNumAliases = {
    'numero', 'number', 'addressnumber', 'num', 'streetnumber',
  };
  static const _addr2Aliases = {
    'shipaddress2', 'address2', 'addressfieldtwo', 'complemento',
    'complement', 'addressline2', 'addrcomplement',
  };
  static const _addr3Aliases = {
    'shipaddress3', 'address3', 'bairro', 'neighborhood', 'district',
  };
  static const _cityAliases = {
    'shipcity', 'city', 'cidade', 'municipio', 'municipality',
  };
  static const _stateAliases = {
    'shipstate', 'state', 'estado', 'uf', 'province', 'region',
  };
  static const _zipAliases = {
    'shippostalcode', 'postalcode', 'zipcode', 'cep', 'zip',
    'postcode', 'postal',
  };
  static const _productAliases = {
    'productname', 'itemname', 'product', 'produto', 'titulodoanuncio',
    'anuncio', 'title', 'description', 'descricao', 'itemdescription',
    'goodsname', 'producttitle', 'itemtitle',
  };
  static const _skuAliases = {
    'sku', 'sellersku', 'skureference', 'skureferenceno', 'orderitemid',
    'trackingnumber', 'codigoderastreio', 'rastreio', 'barcode',
    'codigodebarras', 'itemid', 'merchantsku', 'variationname',
    'spxtn', 'trackingcode',
  };
  static const _qtyAliases = {
    'quantity', 'quantitypurchased', 'numberofitems', 'quantidade',
    'qtd', 'qty', 'units',
  };
  static const _weightAliases = {
    'weight', 'peso', 'itemweight', 'packageweight',
  };
  static const _statusAliases = {
    'orderstatus', 'status', 'statusdopedido',
  };
  static const _latAliases = {
    'latitude', 'lat', 'coordy',
  };
  static const _lngAliases = {
    'longitude', 'lng', 'lon', 'long', 'coordx',
  };
  static const _notesAliases = {
    'observacao', 'observacoes', 'obs', 'observacaoentrega', 'observacaodoentregador',
    'instrucao', 'instrucoes', 'instrucaodeentrega', 'nota', 'notas', 'notes',
    'note', 'comentario', 'comentarios', 'comments', 'comment', 'referencia',
    'pontodereferencia', 'observacoesentrega', 'obsentrega', 'mensagem',
    'observacaopedido', 'deliverynotes', 'deliveryinstructions', 'specialinstructions',
  };

  static int _findColumn(List<String> normHeader, Set<String> aliases) {
    for (int i = 0; i < normHeader.length; i++) {
      if (aliases.contains(normHeader[i])) return i;
    }
    for (int i = 0; i < normHeader.length; i++) {
      for (final a in aliases) {
        if (a.length >= 5 && normHeader[i].contains(a)) return i;
      }
    }
    return -1;
  }

  static String _cell(List<String> row, int col) {
    if (col < 0 || col >= row.length) return '';
    return row[col].trim();
  }

  static int _parseQty(String raw) {
    final n = int.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), ''));
    if (n == null || n <= 0) return 1;
    return n > 20 ? 20 : n;
  }

  static double _parseWeight(String raw) {
    final n = double.tryParse(raw.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), ''));
    if (n == null || n <= 0) return 1.0;
    return n;
  }

  static double? _parseCoord(String raw) {
    final cleaned = raw.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty || cleaned == '-' || cleaned == '.') return null;
    return double.tryParse(cleaned);
  }

  static (double?, double?) _parseLatLng(String rawLat, String rawLng) {
    var lat = _parseCoord(rawLat);
    var lng = _parseCoord(rawLng);
    if (lat == null || lng == null) return (null, null);
    final latOk = lat >= -90 && lat <= 90;
    final lngOk = lng >= -180 && lng <= 180;
    if (!latOk && lngOk && lat >= -180 && lat <= 180) {
      final t = lat;
      lat = lng;
      lng = t;
      return (lat, lng);
    }
    if (!latOk || !lngOk) return (null, null);
    return (lat, lng);
  }

  static ImportParseResult parseRows(List<List<String>> rows) {
    if (rows.isEmpty) {
      throw const ImportException('Arquivo vazio.');
    }
    final header = rows.first;
    final normHeader = header.map(normalizeHeader).toList();
    final format = detectFormat(header);

    final cOrder = _findColumn(normHeader, _orderAliases);
    final cRecipient = _findColumn(normHeader, _recipientAliases);
    final cAddr1 = _findColumn(normHeader, _addr1Aliases);
    final cNum = _findColumn(normHeader, _addrNumAliases);
    final cAddr2 = _findColumn(normHeader, _addr2Aliases);
    final cAddr3 = _findColumn(normHeader, _addr3Aliases);
    final cCity = _findColumn(normHeader, _cityAliases);
    final cState = _findColumn(normHeader, _stateAliases);
    final cZip = _findColumn(normHeader, _zipAliases);
    final cProduct = _findColumn(normHeader, _productAliases);
    final cSku = _findColumn(normHeader, _skuAliases);
    final cQty = _findColumn(normHeader, _qtyAliases);
    final cWeight = _findColumn(normHeader, _weightAliases);
    final cStatus = _findColumn(normHeader, _statusAliases);
    final cLat = _findColumn(normHeader, _latAliases);
    final cLng = _findColumn(normHeader, _lngAliases);
    final cNotes = _findColumn(normHeader, _notesAliases);

    final Map<String, _StopBuilder> grouped = {};
    final List<String> order = [];
    int skippedCancelled = 0;
    int rowsWithoutAddress = 0;

    for (int r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c.isEmpty)) continue;

      if (cStatus >= 0) {
        final st = normalizeHeader(_cell(row, cStatus));
        if (st.contains('cancel')) {
          skippedCancelled++;
          continue;
        }
      }

      var orderRef = _cell(row, cOrder);
      if (orderRef.isEmpty) orderRef = 'PED-$r';

      final addr1 = _cell(row, cAddr1);
      final num = _cell(row, cNum);

      final recipient = _cell(row, cRecipient).isNotEmpty
          ? _cell(row, cRecipient)
          : (addr1.isNotEmpty
              ? (num.isNotEmpty ? '$addr1, $num' : addr1)
              : 'Entrega $r');

      final addr2 = _cell(row, cAddr2);
      final addr3 = _cell(row, cAddr3);
      final city = _cell(row, cCity);
      final state = _cell(row, cState);
      final zip = _cell(row, cZip);

      final parts = <String>[
        if (addr1.isNotEmpty && num.isNotEmpty) '$addr1, $num'
        else if (addr1.isNotEmpty) addr1,
        if (addr2.isNotEmpty) addr2,
        if (addr3.isNotEmpty) addr3,
        if (city.isNotEmpty && state.isNotEmpty) '$city - $state'
        else if (city.isNotEmpty) city,
        if (zip.isNotEmpty) zip,
        'Brasil',
      ];
      if (parts.length == 1) {
        rowsWithoutAddress++;
        continue;
      }
      final query = parts.join(', ');
      final display = parts.length > 1
          ? parts.sublist(0, parts.length - 1).join(', ')
          : query;

      final (fileLat, fileLng) = (cLat >= 0 && cLng >= 0)
          ? _parseLatLng(_cell(row, cLat), _cell(row, cLng))
          : (null, null);
      final notes = cNotes >= 0 ? _cell(row, cNotes) : '';

      final String groupKey;
      if (fileLat != null && fileLng != null) {
        final normRecipient = normalizeHeader(recipient);
        final coordKey = '${fileLat.toStringAsFixed(4)}_${fileLng.toStringAsFixed(4)}';
        groupKey = normRecipient.isNotEmpty ? '${normRecipient}_$coordKey' : 'COORD-$coordKey-$r';
      } else if (addr1.isNotEmpty) {
        final normRecipient = normalizeHeader(recipient);
        final normAddr = normalizeHeader('$addr1 $num $city');
        groupKey = normRecipient.isNotEmpty ? '${normRecipient}_$normAddr' : 'ADDR-$normAddr-$r';
      } else {
        groupKey = 'ROW-$r';
      }

      var sku = _cell(row, cSku);
      if (sku.isEmpty) {
        sku = (cOrder >= 0 && _cell(row, cOrder).isNotEmpty)
            ? '${_cell(row, cOrder)}-$r'
            : 'VOL-${r.toString().padLeft(4, '0')}';
      }
      var desc = _cell(row, cProduct);
      if (desc.isEmpty) desc = 'Pacote $sku';
      final qty = _parseQty(_cell(row, cQty));
      final weight = _parseWeight(_cell(row, cWeight));

      final builder = grouped.putIfAbsent(groupKey, () {
        order.add(groupKey);
        return _StopBuilder(
          orderRef: orderRef,
          recipient: recipient,
          addressQuery: query,
          displayAddress: display,
          latitude: fileLat,
          longitude: fileLng,
          notes: notes.isNotEmpty ? notes : null,
        );
      });
      if (notes.isNotEmpty && (builder.notes == null || builder.notes!.isEmpty)) {
        builder.notes = notes;
      }
      builder.items.add(ImportedItem(
        barcodeBase: sku,
        description: desc,
        quantity: qty,
        weightKg: weight,
      ));
    }

    return ImportParseResult(
      detectedFormat: format,
      stops: [for (final k in order) grouped[k]!.build()],
      skippedCancelled: skippedCancelled,
      rowsWithoutAddress: rowsWithoutAddress,
    );
  }

  static ResolvedImportStop resolve(
    ImportedStop stop,
    double latitude,
    double longitude,
  ) {
    final items = <ResolvedImportItem>[];
    for (final it in stop.items) {
      for (int k = 1; k <= it.quantity; k++) {
        items.add(ResolvedImportItem(
          barcode: it.quantity > 1 ? '${it.barcodeBase}-$k' : it.barcodeBase,
          description: it.description,
          weightKg: it.weightKg,
        ));
      }
    }
    return ResolvedImportStop(
      orderRef: stop.orderRef,
      recipient: stop.recipient,
      address: stop.displayAddress,
      latitude: latitude,
      longitude: longitude,
      notes: stop.notes,
      items: items,
    );
  }
}

class _StopBuilder {
  final String orderRef;
  final String recipient;
  final String addressQuery;
  final String displayAddress;
  final double? latitude;
  final double? longitude;
  String? notes;
  final List<ImportedItem> items = [];

  _StopBuilder({
    required this.orderRef,
    required this.recipient,
    required this.addressQuery,
    required this.displayAddress,
    this.latitude,
    this.longitude,
    this.notes,
  });

  ImportedStop build() => ImportedStop(
        orderRef: orderRef,
        recipient: recipient,
        addressQuery: addressQuery,
        displayAddress: displayAddress,
        latitude: latitude,
        longitude: longitude,
        notes: notes,
        items: List.unmodifiable(items),
      );
}
