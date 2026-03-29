#ifndef ALLOCATOR_HPP
#define ALLOCATOR_HPP

#include <vector>

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

      virtual error free_all();
   }

   struct heap : public allocator
   {
      std::vector<void *> ptrs_;
      
      template<typename T>
      error allocate(T *ptr, size_t size)
      {
         error e{};
         ptr = (T*)malloc(size);
         if (ptr == nullptr)
         {
            e.has_error = true;
            e.error = "memory allocation failed"; 
            return e;
         }
         ptrs_.push_back(ptr);
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

      error free_all()
      {
         for (int i = 0; i < ptrs_.size(); ++i)
         {
            if (ptrs_[i] == nullptr) continue;
            free(ptrs_[i]);
         }
         ptrs_.clear();

         error e{};
         return e;
      }
   }
};

#endif // ALLOCATOR_HPP
