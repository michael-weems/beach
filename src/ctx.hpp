#ifndef CTX_HPP
#define CTX_HPP

#include "allocator.hpp"

namespace ctx
{
   struct ctx
   {
      allocator::allocator *allocator;
   }
   extern ctx default_ctx;
};

#endif // CTX_HPP
