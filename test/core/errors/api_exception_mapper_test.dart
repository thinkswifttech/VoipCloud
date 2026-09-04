import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_app/core/errors/app_exception.dart';
import 'package:phone_app/core/network/api_exception_mapper.dart';

void main() {
  test('maps 401 responses to user-facing auth message', () {
    final exception = DioException(
      requestOptions: RequestOptions(path: '/me'),
      response: Response(
        requestOptions: RequestOptions(path: '/me'),
        statusCode: 401,
        data: {'message': 'token expired'},
      ),
      type: DioExceptionType.badResponse,
    );

    final mapped = ApiExceptionMapper.mapDioException(exception);

    expect(mapped, isA<ApiException>());
    expect(mapped.userMessage, contains('session has expired'));
  });

  test('maps connection timeout to network exception', () {
    final exception = DioException(
      requestOptions: RequestOptions(path: '/calls/history'),
      type: DioExceptionType.connectionTimeout,
    );

    final mapped = ApiExceptionMapper.mapDioException(exception);

    expect(mapped, isA<NetworkException>());
  });
}
