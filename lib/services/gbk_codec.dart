/// GBK 编码（只实现「编码」方向）。
///
/// 第一版主这类老 CMS 的搜索表单是 `accept-charset="GBK"`：关键字必须按 GBK
/// 提交，UTF-8 一律查不到结果。页面本身仍是 UTF-8，所以只需要编码这一段。
///
/// 表来自 `gbk_table.dart`（U+4E00..U+9FFF 双字节映射，base64 存放）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'gbk_table.dart';

Uint8List? _cachedTable;

Uint8List get _table {
  final cached = _cachedTable;
  if (cached != null) return cached;
  return _cachedTable = base64Decode(gbkCjkBase64);
}

/// 把文本编码成 GBK 字节。遇到表里没有的字符返回 null（调用方回退 UTF-8）。
List<int>? encodeGbk(String text) {
  final table = _table;
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      out.add(rune);
      continue;
    }
    final index = rune - gbkCjkStart;
    if (index < 0 || index >= gbkCjkCount) return null;
    final offset = index * 2;
    final high = table[offset];
    final low = table[offset + 1];
    if (high == 0 && low == 0) return null;
    out.add(high);
    out.add(low);
  }
  return out;
}

const String _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*';

/// 按 GBK 字节做百分号编码（空格转 `+`，未保留字符原样）。
///
/// 表里没有的字符退回 [Uri.encodeQueryComponent] 的 UTF-8 行为，避免整条搜索
/// 因为一个生僻字直接失败。
String encodeGbkQueryComponent(String text) {
  final bytes = encodeGbk(text);
  if (bytes == null) return Uri.encodeQueryComponent(text);
  final buffer = StringBuffer();
  for (final byte in bytes) {
    if (byte == 0x20) {
      buffer.write('+');
    } else if (_unreserved.codeUnits.contains(byte)) {
      buffer.writeCharCode(byte);
    } else {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}
