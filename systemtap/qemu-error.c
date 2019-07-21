/**
 * Use systemtap to see va_list
 * cc -g ./qemu-error.c -o qemu-error
 * sudo stap -e 'probe process("./qemu-error").function("error_vreport").return { printf("=> %s(%s)\n", probefunc(), $$parms); printf("  ap=(%s)\n", "aa"); }' -c "./qemu-error"
 *
**/
#include <stdio.h> 
#include <stdlib.h> 
#include <stdarg.h> 

FILE *fp; 

void error_vreport(const char *fmt, va_list ap)
{
    vfprintf(fp, fmt, ap);
}

int error_report(char *fmt, ...) 
{ 
   va_list ap; 
   va_start(ap, fmt); 
   error_vreport(fmt, ap);
   va_end(ap); 
} 

int main(void) 
{ 
   int inumber = 30; 
   float fnumber = 90.0; 
   char string[4] = "abc"; 
   fp = tmpfile(); 
   if (fp == NULL) 
   { 
      perror("tmpfile() call"); 
      exit(1); 
   } 
   error_report("%d %f %s", inumber, fnumber, string); 
   rewind(fp); 
   fscanf(fp,"%d %f %s", &inumber, &fnumber, string); 
   printf("%d %f %s\n", inumber, fnumber, string); 
   fclose(fp); 
   return 0; 
} 
