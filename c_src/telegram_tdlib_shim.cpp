// telegram_tdlib_shim
//
// A minimal bridge between an Erlang/Elixir Port and Telegram's TDLib
// `td_json_client` interface. Messages are framed with a 4-byte big-endian
// length prefix, matching the BEAM `{:packet, 4}` port option:
//
//   stdin  : <len:4><utf8 JSON request>  -> td_send(client_id, request)
//   stdout : <len:4><utf8 JSON response> <- td_receive()
//
// A dedicated reader thread pumps stdin into td_send; the main thread polls
// td_receive and writes framed responses to stdout. TDLib's td_json_client is
// thread-safe across td_send / td_receive, so this split is safe. The string
// returned by td_receive is owned by TDLib until the next td_receive on the
// same thread, so the main loop frames it out immediately before looping.

#include <td/telegram/td_json_client.h>

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>

namespace {

// Upper bound on a single frame. TDLib's JSON payloads are far smaller; this is
// a defense-in-depth cap so a malformed length prefix can't drive an arbitrary
// allocation or desync the stream.
const uint32_t MAX_FRAME_BYTES = 64u * 1024u * 1024u;  // 64 MiB

std::atomic<bool> g_running{true};

bool read_exact(int fd, char *buf, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = ::read(fd, buf + got, n - got);
    if (r == 0) return false;  // EOF — port closed
    if (r < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    got += static_cast<size_t>(r);
  }
  return true;
}

bool write_exact(int fd, const char *buf, size_t n) {
  size_t put = 0;
  while (put < n) {
    ssize_t w = ::write(fd, buf + put, n - put);
    if (w < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    put += static_cast<size_t>(w);
  }
  return true;
}

uint32_t read_be32(const unsigned char *p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}

void write_be32(unsigned char *p, uint32_t v) {
  p[0] = static_cast<unsigned char>((v >> 24) & 0xFF);
  p[1] = static_cast<unsigned char>((v >> 16) & 0xFF);
  p[2] = static_cast<unsigned char>((v >> 8) & 0xFF);
  p[3] = static_cast<unsigned char>(v & 0xFF);
}

// Frame a payload onto stdout. Only the main thread calls this.
bool send_frame(const char *data, size_t len) {
  if (len > MAX_FRAME_BYTES) return false;  // would corrupt the 4-byte header
  unsigned char header[4];
  write_be32(header, static_cast<uint32_t>(len));
  if (!write_exact(STDOUT_FILENO, reinterpret_cast<const char *>(header), 4)) return false;
  return write_exact(STDOUT_FILENO, data, len);
}

// Reader thread: stdin frames -> td_send. Only this thread reads stdin.
void reader_loop(int client_id) {
  unsigned char header[4];
  std::string buf;
  while (g_running.load()) {
    if (!read_exact(STDIN_FILENO, reinterpret_cast<char *>(header), 4)) break;
    uint32_t len = read_be32(header);
    if (len == 0) continue;            // skip empty frames; not a valid request
    if (len > MAX_FRAME_BYTES) break;  // reject implausible frame, don't allocate
    buf.resize(len);
    if (!read_exact(STDIN_FILENO, &buf[0], len)) break;
    // std::string::c_str() is NUL-terminated, so no manual terminator is needed.
    td_send(client_id, buf.c_str());
  }
  g_running.store(false);
}

}  // namespace

int main() {
  // Keep TDLib's own stderr logging quiet by default; the Elixir side can raise
  // verbosity via setLogVerbosityLevel.
  td_execute("{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":1}");

  int client_id = td_create_client_id();

  // Kick the client so its update loop starts producing events.
  td_send(client_id, "{\"@type\":\"getOption\",\"name\":\"version\",\"@extra\":\"bootstrap\"}");

  std::thread reader(reader_loop, client_id);

  while (g_running.load()) {
    const char *res = td_receive(1.0);
    if (res == nullptr) continue;  // poll timeout, no event
    if (!send_frame(res, std::strlen(res))) break;
  }

  g_running.store(false);
  // The reader may still be blocked in read() on stdin (changing g_running does
  // not interrupt a blocking read). Detaching rather than joining avoids a
  // shutdown deadlock; the process is exiting, so the OS reclaims the thread.
  reader.detach();
  return 0;
}
