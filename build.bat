@echo off
nasm -f bin boot.asm -o boot.bin
if %errorlevel% neq 0 exit /b %errorlevel%

nasm -f bin kernel.asm -o kernel.bin
if %errorlevel% neq 0 exit /b %errorlevel%

copy /b boot.bin + kernel.bin os-image.bin >nul
qemu-system-i386 -drive format=raw,file=os-image.bin

