import 'package:dsh_app/state/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('follow-stream reopen backoff is capped, jittered and never gives up', () {
    Duration delay(int retries) => ChatController.followRetryDelay(retries);

    expect(delay(0).inMilliseconds, inInclusiveRange(800, 1200));
    expect(delay(1).inMilliseconds, inInclusiveRange(1600, 2400));
    expect(delay(2).inMilliseconds, inInclusiveRange(3200, 4800));
    expect(delay(3).inMilliseconds, inInclusiveRange(6400, 9600));
    expect(delay(4).inMilliseconds, inInclusiveRange(12800, 19200));
    for (var retries = 5; retries < 50; retries++) {
      expect(
        delay(retries).inMilliseconds,
        inInclusiveRange(24000, 36000),
        reason: 'attempt $retries must keep retrying (capped at 30s), '
            'otherwise a stream that ends while the mux stays connected leaves syncing forever',
      );
    }
  });
}
