import 'package:http/http.dart' as http;

final _client = http.Client();

http.Client transportClient(Duration timeout) => _client;
