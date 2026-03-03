#ifndef ANSI_COLORS_HPP
#define ANSI_COLORS_HPP

#include <string>
#include <string_view>

namespace ansi_color
{

const std::string RED = "\x1b[31m";
const std::string GREEN = "\x1b[32m";
const std::string UNSET = "\x1b[0m";

inline std::string red(std::string_view text)
{
   return std::format("{}{}{}", RED, text, UNSET);
}

};
#endif
