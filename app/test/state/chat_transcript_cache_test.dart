import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/state/chat_transcript_cache.dart';

void main() {
  test('the same host and session get the same transcript back', () {
    final cache = ChatTranscriptCache();
    final first = cache.acquire('ssh:box', 's1');
    final again = cache.acquire('ssh:box', 's1');
    expect(identical(first, again), isTrue);
    expect(cache.length, 1);
  });

  test('the same session id on another host is another log', () {
    final cache = ChatTranscriptCache();
    final local = cache.acquire('local:local', 's1');
    final remote = cache.acquire('ssh:box', 's1');
    expect(identical(local, remote), isFalse);
    expect(cache.length, 2);
  });

  test('the least recently used transcript is evicted first', () {
    final cache = ChatTranscriptCache(maxSessions: 2);
    final a = cache.acquire('local:local', 'a');
    cache.acquire('local:local', 'b');
    cache.acquire('local:local', 'a'); // a becomes most recent
    cache.acquire('local:local', 'c'); // evicts b
    expect(cache.length, 2);
    expect(identical(cache.acquire('local:local', 'a'), a), isTrue);
    expect(identical(cache.acquire('local:local', 'b'), a), isFalse);
  });

  test('evict drops one entry', () {
    final cache = ChatTranscriptCache();
    cache.acquire('local:local', 'a');
    cache.evict('local:local', 'a');
    expect(cache.length, 0);
  });
}
