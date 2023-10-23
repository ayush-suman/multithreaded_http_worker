import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http_worker/http_worker.dart';
import 'package:multithreaded_http_worker/src/request_store_manager.dart';
import 'package:multithreaded_http_worker/src/utils.dart';

import 'constants.dart';

class MultithreadedHttpWorker extends HttpWorker {
  MultithreadedHttpWorker({this.debug = true, this.maxThreads = 1}): super();

  final bool debug;
  final int maxThreads;
  late final Isolate _isolate;
  late final SendPort _sendPort;

  void _getResponseOrKill(Map<String, Object?> data, RequestStoreManager requestStoreManager, HttpClient? withClient) {
    final int id = data[ID]! as int;
    final String action = data[ACTION]! as String;

    if (action == 'kill') {
      _cancelRequest(requestId: id, requestStoreManager: requestStoreManager);
      return;
    }

    final RequestMethod method = data[METHOD]! as RequestMethod;
    final Uri url = data[URL]! as Uri;
    final Map<String, String>? header = data[HEADER] as Map<String, String>?;
    final Object? requestBody = data[BODY];
    final Parser<dynamic>? parser = data[PARSER] as Parser<dynamic>?;
    final SendPort sendPort = data[SEND_PORT]! as SendPort;

    final HttpClient client = withClient??HttpClient();

    client.openUrl(method.string, url).then((HttpClientRequest request) async {
      requestStoreManager.storeHttpRequest(requestId: id, request: request);
      try {
        if (header != null) {
          header.forEach((key, value) {
            request.headers.add(key, value);
          });
        }
        if (requestBody != null) {
          final Encoding encoding = encodingForCharset(request.headers.contentType?.charset);
          if (requestBody is Map) {
            if (request.headers.contentType == null) {
              request.headers.contentType = ContentType.parse('application/x-www-form-urlencoded');
              request.write(encoding.encode(mapToQuery(requestBody.cast<String, String>())));
            } else if (request.headers.contentType == ContentType.parse('application/x-www-form-urlencoded')) {
              request.write(encoding.encode(mapToQuery(requestBody.cast<String, String>())));
            } else if (request.headers.contentType == ContentType.parse('multipart/form-data')) {
              const String boundary = 'dart-http-boundary';
              request.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
              requestBody.forEach((key, value) {
                request.write(encoding.encode('--$boundary\r\n'));
                request.write(encoding.encode('Content-Disposition: form-data; name="$key"\r\n\r\n'));
                request.write(encoding.encode('$value\r\n'));
              });
              request.write(encoding.encode('--$boundary--'));
            } else if (request.headers.contentType == ContentType.json) {
              request.write(encoding.encode(jsonEncode(requestBody)));
            } else {
              request.write(encoding.encode(requestBody.toString()));
            }
          } else if (requestBody is List) {
            if (requestBody is List<int>) {
              request.write(requestBody);
            } else if (request.headers.contentType == ContentType.json) {
              request.write(encoding.encode(jsonEncode(requestBody)));
            } else {
              request.write(requestBody.cast<int>());
            }
          } else {
            final String bodyString = requestBody.toString();
            request.write(encoding.encode(bodyString));
          }
        }
        final HttpClientResponse response = await request.close();
        final Completer<Uint8List> completer = Completer<Uint8List>();
        final sink = ByteConversionSink.withCallback((bytes) {
          completer.complete(Uint8List.fromList(bytes));
        });
        response.listen(sink.add, onError: completer.completeError, onDone: sink.close);
        final Uint8List bytes = await completer.future;
        final Encoding encoding = encodingForCharset(response.headers.contentType?.charset);
        final String body = encoding.decode(bytes);
        final parsedBody = parser?.parse(body);
        sendPort.send({
          ID: id,
          DATA: parsedBody ?? body,
          STATUS_CODE: response.statusCode
        });
        requestStoreManager.removeFromStore(id);
      } catch (e) {
        sendPort.send({ID: id, STATUS_CODE: -1, ERROR: e});
        requestStoreManager.removeFromStore(id);
      }
    });
  }

  void _cancelRequest({required int requestId, required RequestStoreManager requestStoreManager, int tryCount = 0}) {
    try {
      if (tryCount > 3) {
        return;
      }
      requestStoreManager.cancelRequest(requestId: requestId);
    } catch (e) {
      Future.delayed(const Duration(seconds: 1), () {
        _cancelRequest(requestId: requestId, requestStoreManager: requestStoreManager, tryCount: tryCount + 1);
      });
    }
  }

  @override
  Future init() async {
    final ReceivePort receivePort0 = ReceivePort();
    _isolate = await Isolate.spawn<SendPort>((sendPort) {
      final RequestStoreManager storeManager = RequestStoreManager();

      final HttpClient baseUrlClient = HttpClient();

      final receivePort = ReceivePort();
      sendPort.send(receivePort.sendPort);

      receivePort.listen((message) {
        HttpClient? client;
        final Map<String, Object?> data = (message as Map<String, Object?>);
        final Map<String, Object?> meta = data[META]! as Map<String, Object?>;
        client = meta["using_base_url"] as bool ? baseUrlClient : null;
        _getResponseOrKill(message, storeManager, client);
      });
    }, receivePort0.sendPort);
    _sendPort = await receivePort0.first;
  }

  @override
  (Completer<Response<T>>, {Object? meta}) processRequest<T>(
      {required int id,
        required RequestMethod method,
        required Uri url,
        Map<String, String>? header,
        Object? body,
        Parser<T>? parser,
        Map<String, Object?>? meta}) {

    final Completer<Response<T>> completer = Completer<Response<T>>();

    final ReceivePort responsePort = ReceivePort();

    _sendPort.send({
      ID: id,
      URL: url,
      METHOD: method,
      HEADER: header,
      BODY: body,
      META: meta,
      PARSER: parser,
      ACTION: 'request',
      SEND_PORT: responsePort.sendPort,
    });

    responsePort.first.then((data) {
      final dataMap = data as Map<String, Object?>;
      if (!(completer.isCompleted)) {
        final response = Response<T>(
            data: dataMap[DATA] as T?,
            status: dataMap[STATUS_CODE]! as int,
            error: dataMap[ERROR]);
        completer.complete(response);
      }
    });

    return (completer, meta: null);
  }

  @override
  Future killRequest(int id) async {
    _sendPort.send({
      ID: id,
      ACTION: 'kill',
    });
  }

  @override
  destroy() {
    _isolate.kill();
  }
}