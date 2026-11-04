import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

final _clients = <Duration, http.Client>{};

/// Immutable connection configuration per pool; cancellation is request scoped.
http.Client transportClient(Duration timeout) => _clients.putIfAbsent(
      timeout,
      () => IOClient(io.HttpClient()..connectionTimeout = timeout),
    );
