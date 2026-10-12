#define main WindowFrameProbeMain
#import "WindowFrameProbe.m"
#undef main

static void pixel(unsigned char *row, size_t x, unsigned char red, unsigned char green, unsigned char blue) {
    row[x*4] = blue; row[x*4+1] = green; row[x*4+2] = red; row[x*4+3] = 255;
}

int main(void) {
    @autoreleasepool {
        CVPixelBufferRef image = NULL;
        if (CVPixelBufferCreate(kCFAllocatorDefault,400,16,kCVPixelFormatType_32BGRA,NULL,&image) != kCVReturnSuccess) return 1;
        CVPixelBufferLockBaseAddress(image,0);
        unsigned char *base = CVPixelBufferGetBaseAddress(image);
        size_t stride = CVPixelBufferGetBytesPerRow(image);
        uint32_t expected = 0x0017beef;
        expected |= (uint32_t)(uint8_t)(expected ^ (expected>>8) ^ (expected>>16) ^ 0xa5) << 24;
        for (size_t y=0;y<16;y++) {
            unsigned char *row = base+y*stride;
            for (size_t x=0;x<400;x++) pixel(row,x,255,255,255);
            for (size_t cell=0;cell<36;cell++) for (size_t x=20+cell*10;x<30+cell*10;x++) {
                if (cell==0) pixel(row,x,255,0,255);
                else if (cell==1) pixel(row,x,0,255,255);
                else if (cell==2) pixel(row,x,255,255,0);
                else if (cell==35) pixel(row,x,0,255,0);
                else { unsigned char v = (expected>>(cell-3))&1 ? 255:0; pixel(row,x,v,v,v); }
            }
        }
        CVPixelBufferUnlockBaseAddress(image,0);
        uint32_t decoded=0; NSString *reason=nil; NSDictionary *marker=nil;
        if (!decode(image,nil,&decoded,&reason,&marker) || decoded!=expected) return 2;
        CVPixelBufferLockBaseAddress(image,0);
        for (size_t y=0;y<16;y++) pixel(base+y*stride,39,127,255,127);
        CVPixelBufferUnlockBaseAddress(image,0);
        if (!decode(image,nil,&decoded,&reason,&marker) || decoded!=expected) return 3;
        CVPixelBufferLockBaseAddress(image,0);
        for (size_t y=0;y<16;y++) for (size_t x=50;x<60;x++) pixel(base+y*stride,x,0,0,0);
        CVPixelBufferUnlockBaseAddress(image,0);
        if (decode(image,nil,&decoded,&reason,&marker)) return 4;
        CVPixelBufferLockBaseAddress(image,0);
        for (size_t y=0;y<16;y++) {
            unsigned char *row = base+y*stride;
            for (size_t x=0;x<400;x++) pixel(row,x,255,255,255);
            for (size_t x=392;x<400;x++) pixel(row,x,255,0,255);
        }
        CVPixelBufferUnlockBaseAddress(image,0);
        if (decode(image,nil,&decoded,&reason,&marker) || ![reason isEqual:@"green-missing"]) return 5;
        CVPixelBufferRelease(image);
        if (CVPixelBufferCreate(kCFAllocatorDefault,900,16,kCVPixelFormatType_32BGRA,NULL,&image) != kCVReturnSuccess) return 6;
        uint32_t right = 0x0028cafe;
        right |= (uint32_t)(uint8_t)(right ^ (right>>8) ^ (right>>16) ^ 0xa5) << 24;
        CVPixelBufferLockBaseAddress(image,0);
        base = CVPixelBufferGetBaseAddress(image); stride = CVPixelBufferGetBytesPerRow(image);
        for (size_t y=0;y<16;y++) {
            unsigned char *row = base+y*stride;
            for (size_t x=0;x<900;x++) pixel(row,x,255,255,255);
            for (size_t side=0;side<2;side++) {
                size_t origin = side ? 500:20; uint32_t code = side ? right:expected;
                for (size_t cell=0;cell<36;cell++) for (size_t x=origin+cell*10;x<origin+(cell+1)*10;x++) {
                    if (cell==0) pixel(row,x,255,0,255);
                    else if (cell==1) pixel(row,x,0,255,255);
                    else if (cell==2) pixel(row,x,255,255,0);
                    else if (cell==35) pixel(row,x,0,255,0);
                    else { unsigned char v=(code>>(cell-3))&1 ? 255:0; pixel(row,x,v,v,v); }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(image,0);
        if (!decode(image,@"left",&decoded,&reason,&marker) || decoded!=expected) return 7;
        if (!decode(image,@"right",&decoded,&reason,&marker) || decoded!=right) return 8;
        CVPixelBufferLockBaseAddress(image,0);
        for (size_t y=0;y<16;y++) for (size_t x=50;x<60;x++) pixel(base+y*stride,x,0,0,0);
        CVPixelBufferUnlockBaseAddress(image,0);
        if (decode(image,@"left",&decoded,&reason,&marker)) return 9;
        if (!decode(image,@"right",&decoded,&reason,&marker) || decoded!=right) return 10;
        CVPixelBufferRelease(image);
        puts("Passed: original marker, interpolated header, corrupt checksum, right-edge rejection and independent left/right markers");
        return 0;
    }
}
