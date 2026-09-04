import 'package:dio/dio.dart';

import '../errors/app_exception.dart';
import 'api_exception_mapper.dart';

class AppClient {
  const AppClient(this._dio);

  final Dio _dio;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    return _send(() => _dio.get<T>(path, queryParameters: queryParameters));
  }

  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    return _send(
      () => _dio.post<T>(path, data: data, queryParameters: queryParameters),
    );
  }

  Future<Response<T>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    return _send(
      () => _dio.put<T>(path, data: data, queryParameters: queryParameters),
    );
  }

  Future<Response<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
  }) async {
    return _send(
      () => _dio.delete<T>(path, data: data, queryParameters: queryParameters),
    );
  }

  Future<Response<T>> _send<T>(Future<Response<T>> Function() request) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw ApiExceptionMapper.mapDioException(error);
    } on AppException {
      rethrow;
    } catch (error) {
      throw AppException(message: error.toString());
    }
  }
}
