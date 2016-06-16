//
//  metrics.cpp
//  Pods
//
//  Created by Chamara Susantha on 14/6/16.
//
//

#include <stdio.h>
#include <string>

namespace webrtc {
    namespace metrics {
        class Histogram;
        
        // Implementation of histogram methods in
        // webrtc/system_wrappers/interface/metrics.h.
        Histogram* HistogramFactoryGetCounts(const std::string& name,
                                             int min,
                                             int max,
                                             int bucket_count) {
            return nullptr;
        }
        
        Histogram* HistogramFactoryGetEnumeration(const std::string& name,
                                                  int boundary) {
            return nullptr;
        }
        
        void HistogramAdd(Histogram* histogram_pointer,
                          const std::string& name,
                          int sample) {
            return;
        }
    }
}
