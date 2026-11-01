import 'dart:async';
import 'dart:convert';
import 'dart:io';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  require(args.length == 1, 'Explicit private fixture configuration required');
  final input = File(args.single);
  require(
    input.isAbsolute && !await FileSystemEntity.isLink(input.path),
    'Private absolute input required',
  );
  final stat = await input.stat();
  require(
    stat.size < 128 * 1024 && stat.mode & 0x3f == 0,
    'Private bounded input required',
  );
  final config = jsonDecode(await input.readAsString()) as Map;
  require(
    config['kind'] == 'owned-realtime-websocket-probe' &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch(config['runId'] as String),
    'Owned runtime identity required',
  );
  final checks = <String>[];
  var maxMessageBytes = 0;
  void check(bool value, String name) {
    require(value, name);
    checks.add(name);
    stdout.writeln('REALTIME_CHECK=$name');
  }

  final result = <String, dynamic>{
    'kind': 'actual-native-realtime-websocket-probe',
    'runId': config['runId'],
    'status': 'RUNNING',
    'productionModified': false,
    'wholeApplicationComplete': false,
    'checks': checks,
  };
  final prefix = config['evidencePrefix'] as String? ?? 'realtime-websocket';
  require(
    RegExp(r'^[a-z-]{1,64}$').hasMatch(prefix),
    'Owned evidence prefix required',
  );
  final output = File('${input.parent.path}/$prefix-result.json');
  try {
    final projects = config['projects'] as List;
    require(
      projects.isNotEmpty && projects.length <= 2,
      'Explicit project selection required',
    );
    for (final raw in projects) {
      final project = raw as Map;
      final name = project['project'] as String;
      final tenant = project['tenant'] as String;
      final origin = Uri.parse(project['origin'] as String);
      final address = InternetAddress.tryParse(origin.host);
      require(
        {'pos', 'office'}.contains(name) &&
            tenant == 'realtime-$name' &&
            origin.scheme == 'http' &&
            origin.port == 4000 &&
            origin.path.isEmpty &&
            origin.userInfo.isEmpty &&
            origin.query.isEmpty &&
            address != null &&
            address.type == InternetAddressType.IPv4,
        'Owned numeric fixture origin required',
      );
      final octets = address!.rawAddress;
      require(
        octets[0] == 10 ||
            octets[0] == 127 ||
            octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31 ||
            octets[0] == 192 && octets[1] == 168,
        'Public targets forbidden',
      );
      final http = HttpClient()..findProxy = (_) => 'DIRECT';
      http.connectionFactory = (uri, proxyHost, proxyPort) {
        require(
          uri.host == tenant && uri.port == 4000 && proxyHost == null,
          'Socket cannot leave its owned fixture',
        );
        return Socket.startConnect(address, 4000);
      };
      final gateway = Uri.parse(project['gatewayOrigin'] as String);
      require(
        gateway.scheme == 'http' &&
            gateway.host == '127.0.0.1' &&
            gateway.hasPort &&
            gateway.port > 0 &&
            gateway.path.isEmpty &&
            gateway.userInfo.isEmpty &&
            !gateway.hasQuery &&
            !gateway.hasFragment,
        'Owned loopback API gateway required',
      );
      final websocketHttp = HttpClient()..findProxy = (_) => 'DIRECT';
      websocketHttp.connectionFactory = (uri, proxyHost, proxyPort) {
        require(
          uri.host == gateway.host &&
              uri.port == gateway.port &&
              proxyHost == null,
          'WebSocket cannot leave its owned gateway',
        );
        return Socket.startConnect(InternetAddress.loopbackIPv4, gateway.port);
      };
      Future<WebSocket> connect(String key) {
        require(key.length <= 8192, 'Fixture key bound');
        final uri = Uri(
          scheme: 'ws',
          host: gateway.host,
          port: gateway.port,
          path: '/realtime/v1/websocket',
          queryParameters: {'apikey': key, 'vsn': '1.0.0'},
        );
        return WebSocket.connect(
          uri.toString(),
          customClient: websocketHttp,
          compression: CompressionOptions.compressionOff,
        ).timeout(const Duration(seconds: 8));
      }

      WebSocket? socket;
      StreamIterator<dynamic>? messages;
      try {
        socket = await connect(project['anon'] as String);
        messages = StreamIterator(socket);
        Future<Map> reply(String reference) async {
          for (var i = 0; i < 20; i++) {
            require(
              await messages!.moveNext().timeout(const Duration(seconds: 10)),
              'Socket ended before reply',
            );
            final raw = messages.current;
            require(
              raw is String && utf8.encode(raw).length <= 65536,
              'Realtime message bound',
            );
            maxMessageBytes =
                maxMessageBytes < utf8.encode(raw as String).length
                ? utf8.encode(raw).length
                : maxMessageBytes;
            final value = jsonDecode(raw) as Map;
            if (value['ref'] == reference && value['event'] == 'phx_reply') {
              return value;
            }
          }
          throw StateError('Realtime reply bound');
        }

        Map<String, dynamic> join(
          String topic,
          String token,
          bool private,
          String ref,
        ) => {
          'topic': 'realtime:$topic',
          'event': 'phx_join',
          'ref': ref,
          'join_ref': ref,
          'payload': {
            'access_token': token,
            'config': {
              'broadcast': {'ack': true, 'self': true},
              'presence': {'enabled': false},
              'postgres_changes': [],
              'private': private,
            },
          },
        };
        final topic = 'fixture-${config['runId']}';
        socket.add(
          jsonEncode(join(topic, project['userToken'] as String, false, '1')),
        );
        check(
          (await reply('1'))['payload']['status'] == 'ok',
          '$name-real-auth-public-channel-joined',
        );
        socket.add(
          jsonEncode({
            'topic': 'realtime:$topic',
            'event': 'broadcast',
            'ref': '2',
            'join_ref': '1',
            'payload': {
              'type': 'broadcast',
              'event': 'fixture_ping',
              'payload': {'runId': config['runId']},
            },
          }),
        );
        var acknowledged = false, echoed = false;
        for (var i = 0; i < 10 && !(acknowledged && echoed); i++) {
          require(
            await messages.moveNext().timeout(const Duration(seconds: 10)),
            'Broadcast ended',
          );
          final raw = messages.current;
          require(
            raw is String && utf8.encode(raw).length <= 65536,
            'Broadcast message bound',
          );
          final bytes = utf8.encode(raw as String).length;
          if (bytes > maxMessageBytes) maxMessageBytes = bytes;
          final value = jsonDecode(raw) as Map;
          if (value['event'] == 'phx_reply' && value['ref'] == '2') {
            acknowledged = value['payload']['status'] == 'ok';
          } else if (value['event'] == 'broadcast') {
            echoed =
                value['payload']['event'] == 'fixture_ping' &&
                value['payload']['payload']['runId'] == config['runId'];
          }
        }
        check(acknowledged && echoed, '$name-actual-server-broadcast-and-ack');
        final deniedTopic = 'kds:70000000-0000-4000-8000-000000000099:control';
        socket.add(
          jsonEncode(
            join(deniedTopic, project['userToken'] as String, true, '3'),
          ),
        );
        final denied = (await reply('3'))['payload'] as Map;
        result.putIfAbsent('privateDeniedReplies', () => <String, dynamic>{});
        (result['privateDeniedReplies'] as Map)[name] = denied;
        check(
          denied['status'] == 'error' &&
              jsonEncode(
                denied['response'],
              ).toLowerCase().contains('permission'),
          '$name-real-private-message-rls-denies-unassigned-topic',
        );
        if (project['allowedStore'] != null) {
          final store = project['allowedStore'] as String,
              other = project['otherStore'] as String;
          final uuid = RegExp(r'^[a-f0-9-]{36}$');
          require(
            uuid.hasMatch(store) && uuid.hasMatch(other) && store != other,
            'Distinct registered stores required',
          );
          final control = 'kds:$store:control', kitchen = 'kds:$store:kitchen';
          socket.add(
            jsonEncode(
              join(control, project['userToken'] as String, true, '4'),
            ),
          );
          check(
            (await reply('4'))['payload']['status'] == 'ok',
            '$name-new-store-kitchen-control-authorized',
          );
          socket.add(
            jsonEncode(
              join(kitchen, project['userToken'] as String, true, '5'),
            ),
          );
          check(
            (await reply('5'))['payload']['status'] == 'ok',
            '$name-new-store-kitchen-station-authorized',
          );
          // Wait for the real tenant WAL/DB connection before sending a real
          // database broadcast. No mocked message or success flag is injected.
          var connected = false;
          for (var i = 0; i < 30; i++) {
            final request = await http.getUrl(
              Uri.http('$tenant:4000', '/api/tenants/$tenant/health'),
            );
            request.headers.set(
              'Authorization',
              'Bearer ${project['service']}',
            );
            final response = await request.close().timeout(
              const Duration(seconds: 3),
            );
            final raw = await utf8.decoder
                .bind(response)
                .join()
                .timeout(const Duration(seconds: 3));
            final data = (jsonDecode(raw) as Map)['data'] as Map;
            connected =
                response.statusCode == 200 &&
                data['db_connected'] == true &&
                data['replication_connected'] == true;
            if (connected) break;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
          require(
            connected,
            'Realtime tenant WAL and DB must actually connect',
          );
          final container = project['dbContainer'] as String;
          require(
            container ==
                    'pos-runtime-${(config['runId'] as String).substring(0, 12)}-$name-db' &&
                Platform.environment['POS_LOCAL_RUN_ID'] == config['runId'],
            'Only this owned fixture database is callable',
          );
          final sql =
              "SELECT realtime.send(jsonb_build_object('runId','${config['runId']}'),'kds_change','$control',true);";
          final sent = await Process.run(
            'docker',
            [
              'exec',
              '-i',
              '--env',
              'PGPASSWORD',
              '--env',
              'PGOPTIONS',
              container,
              'psql',
              '-X',
              '-qAt',
              '-U',
              'supabase_admin',
              '-d',
              'postgres',
              '-v',
              'ON_ERROR_STOP=1',
              '-c',
              sql,
            ],
            environment: {
              ...Platform.environment,
              'PGPASSWORD': project['dbPassword'] as String,
              'PGOPTIONS': '-c supautils.hint_roles=',
            },
          );
          require(
            sent.exitCode == 0,
            'Native Realtime send must commit successfully',
          );
          var delivered = false;
          for (var i = 0; i < 20 && !delivered; i++) {
            require(
              await messages.moveNext().timeout(const Duration(seconds: 10)),
              'Native broadcast ended',
            );
            final raw = messages.current;
            require(
              raw is String && utf8.encode(raw).length <= 65536,
              'Native message bound',
            );
            final value = jsonDecode(raw as String) as Map;
            delivered =
                value['event'] == 'broadcast' &&
                value['topic'] == 'realtime:$control' &&
                value['payload']['event'] == 'kds_change' &&
                value['payload']['payload']['runId'] == config['runId'];
          }
          check(
            delivered,
            '$name-native-database-kds-change-reaches-registered-kitchen',
          );
          socket.add(
            jsonEncode(
              join(
                'kds:$other:control',
                project['userToken'] as String,
                true,
                '6',
              ),
            ),
          );
          final outside = (await reply('6'))['payload'] as Map;
          check(
            outside['status'] == 'error' &&
                jsonEncode(
                  outside['response'],
                ).toLowerCase().contains('permission'),
            '$name-other-new-store-kds-channel-is-denied',
          );
        }
      } finally {
        try {
          await socket?.close().timeout(const Duration(seconds: 2));
        } finally {
          try {
            await messages?.cancel().timeout(const Duration(seconds: 2));
          } finally {
            http.close(force: true);
            websocketHttp.close(force: true);
          }
        }
      }
    }
    result['maxMessageBytes'] = maxMessageBytes;
    result['status'] = 'PASS';
  } finally {
    if (result['status'] == 'RUNNING') result['status'] = 'FAIL';
    await output.writeAsString('${jsonEncode(result)}\n', flush: true);
    await Process.run('chmod', ['600', output.path]);
  }
}
