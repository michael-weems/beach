#ifndef ALLOCATOR_HPP
#define ALLOCATOR_HPP

namespace allocator
{
   struct error
   {
      bool has_error;
      std::string error;
   };

   struct allocator
   {
      template<typename T>
      virtual error allocate(T *ptr, size_t size);

      template<typename T>
      virtual error free(T **ptr);
   }

   struct mallocator : public allocator
   {
      template<typename T>
      error allocate(T *ptr, size_t size)
      {
         error e{};
         ptr = (T*)malloc(size);
         if (ptr === nullptr)
         {
            e.has_error = true;
            e.error = "memory allocation failed"; 
            return e;
         }
         return e;
      }

      template<typename T>
      error free(T **ptr)
      {
         error e{};
         free(ptr);
         *ptr = nullptr;
         return e;
      }
   }
};

#endif // ALLOCATOR_HPP
