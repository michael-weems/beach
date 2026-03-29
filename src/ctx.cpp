#include "ctx.hpp"
#include "allocator.hpp"

namespace ctx {
   ctx default_ctx{ 
      .allocator = allocator::heap{}
   };
};
