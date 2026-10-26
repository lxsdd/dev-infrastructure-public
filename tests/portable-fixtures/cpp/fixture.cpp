#include <iostream>
#include <stdexcept>
#include <string_view>

static int parse_byte(std::string_view s) {
  if (s.empty()) throw std::invalid_argument("missing byte");
  int n = 0;
  for (const char c : s) {
    if (c < '0' || c > '9') throw std::invalid_argument("not decimal");
    n = n * 10 + (c - '0');
    if (n > 255) throw std::out_of_range("byte");
  }
  return n;
}
int main(int argc, char** argv) {
  if (argc != 2) return 3;
  const std::string_view mode(argv[1]);
  if (mode == "--expected-nonzero") return 9;
  if (mode != "--checks") return 3;
  try {
    if (parse_byte("0") != 0 || parse_byte("255") != 255 || parse_byte("01") != 1) return 4;
    for (auto v : {"", "-1", "256", "x", "99999999999999999999999"}) {
      bool rejected = false;
      try { (void)parse_byte(v); } catch (const std::exception&) { rejected = true; }
      if (!rejected) return 5;
    }
    std::cout << "PASS: deterministic positive/negative boundary fixture\n";
    return 0;
  } catch (...) { return 6; }
}
