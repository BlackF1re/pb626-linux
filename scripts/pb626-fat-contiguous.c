/* Read-only FAT16 extent verification for the factory 32 MiB p2.
 * Never writes the device. Accept only this board's verified geometry. */
#define _FILE_OFFSET_BITS 64
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>

static unsigned char fat[32768], mirror[32768], root[8192], cluster[2048];
static int fd;
static void fail(const char *msg) {
    fprintf(stderr,"FAT verification failed: %s\n",msg);
    exit(1);
}
static unsigned le16(const unsigned char *p) {
    return (unsigned)p[0] | ((unsigned)p[1]<<8);
}
static uint32_t le32(const unsigned char *p) {
    return le16(p) | ((uint32_t)le16(p+2)<<16);
}
static void read_at(void *p,size_t n,off_t o) {
    unsigned char *b=p;
    while(n) {
        ssize_t k=pread(fd,b,n,o);
        if(k<=0) fail("short read");
        b+=k; n-=(size_t)k; o+=k;
    }
}
static int valid(unsigned cl) { return cl>=2 && cl<16349; }
static unsigned next(unsigned cl) {
    if(!valid(cl)) fail("invalid cluster");
    return le16(fat+2*cl);
}
static unsigned char *find(unsigned char *p,size_t len,const char *name,int dir) {
    for(size_t i=0;i<len;i+=32) {
        unsigned char *e=p+i;
        if(!e[0]) break;
        if(e[0]==0xe5 || (e[11]&8)) continue;
        if(!!(e[11]&16)!=dir) continue;
        if(!memcmp(e,name,11)) return e;
    }
    return NULL;
}
int main(int argc,char **argv) {
    if(argc!=4 || strlen(argv[2])>8 || strlen(argv[3])!=3)
        fail("usage: device SHORTNAME EXT");
    char name[12]="           ";
    memcpy(name,argv[2],strlen(argv[2])); memcpy(name+8,argv[3],3);
    fd=open(argv[1],O_RDONLY);
    if(fd<0) fail("open");
    unsigned char boot[512];
    read_at(boot,sizeof boot,0);
    if(le16(boot+11)!=512 || boot[13]!=4 || le16(boot+14)!=1 ||
        boot[16]!=2 || le16(boot+17)!=256 || le16(boot+22)!=64 ||
        (le16(boot+19)?le16(boot+19):le32(boot+32))!=65536)
        fail("unexpected BPB");
    read_at(fat,sizeof fat,512);
    read_at(mirror,sizeof mirror,65*512);
    if(memcmp(fat,mirror,sizeof fat)) fail("FAT mirrors differ");
    read_at(root,sizeof root,129*512);
    unsigned char *e=find(root,sizeof root,"LINUX      ",1);
    if(!e) fail("linux directory missing");
    unsigned cl=le16(e+26), visits=0;
    while(valid(cl) && visits++<16347) {
        read_at(cluster,sizeof cluster,(off_t)(145+(cl-2)*4)*512);
        e=find(cluster,sizeof cluster,name,0);
        if(e) break;
        cl=next(cl);
    }
    if(!e) fail("payload missing");
    unsigned first=le16(e+26);
    uint32_t size=le32(e+28);
    if(!size || size>0x800000) fail("payload size");
    unsigned count=(size+2047)/2048;
    cl=first;
    for(unsigned i=0;i<count;i++) {
        if(!valid(cl) || cl!=first+i) fail("payload fragmented");
        unsigned n=next(cl);
        if(i+1==count) {
            if(n<0xfff8) fail("invalid chain termination");
        } else if(n!=cl+1) fail("payload fragmented");
        cl=n;
    }
    printf("FAT16 payload contiguous: %u bytes, %u clusters, start %u\n",size,count,first);
    close(fd);
    return 0;
}
