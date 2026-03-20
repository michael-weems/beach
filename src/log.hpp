#ifndef LOG_HPP
#define LOG_HPP

#include <iostream>
#include <string>

namespace log
{
   // TODO: debugf
   void debug(std::string_view msg)
   {
      std::cout << "DEBUG >> " << msg << std::endl;
   }

   void assert(bool condition, std::string_view msg)
   {
      if (condition)
      {
         return;
      } 

      std::cout << "ASSERT >> " << msg << std::endl;
      exit(1);
   }

   // TODO: assertf
};

#endif // LOG_HPP
