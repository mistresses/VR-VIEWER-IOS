# Video pipeline fix v3

Uses VideoToolbox for H.264 decoding and iOS 17+ AVSampleBufferVideoRenderer through AVSampleBufferDisplayLayer.sampleBufferRenderer for rendering. Uses 420v hardware-decoder output, documented CoreMedia attachments, and renderer flush/recovery.
