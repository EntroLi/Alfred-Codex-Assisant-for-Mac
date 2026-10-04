// One-time legacy login-item migration via the system API; never edits a runtime database.
#include <CoreServices/CoreServices.h>
#include <stdio.h>
#include <string.h>
static int matches(LSSharedFileListItemRef item, const char *path) {
    CFURLRef url=LSSharedFileListItemCopyResolvedURL(item,kLSSharedFileListNoUserInteraction|kLSSharedFileListDoNotMountVolumes,NULL);
    if(!url)return 0;
    char resolved[4096];int result=CFURLGetFileSystemRepresentation(url,true,(UInt8*)resolved,sizeof(resolved)) && strcmp(resolved,path)==0;
    CFRelease(url);return result;
}
static int count(LSSharedFileListRef list,const char *path) {
    CFArrayRef items=LSSharedFileListCopySnapshot(list,NULL);if(!items)return -1;
    int n=0;for(CFIndex i=0;i<CFArrayGetCount(items);i++)n+=matches((LSSharedFileListItemRef)CFArrayGetValueAtIndex(items,i),path);
    CFRelease(items);return n;
}
int main(int argc,char **argv) {
    if(argc!=4 || (strcmp(argv[1],"--inspect") && strcmp(argv[1],"--migrate")))return 2;
    const char *old=argv[2],*dest=argv[3];
    LSSharedFileListRef list=LSSharedFileListCreate(NULL,kLSSharedFileListSessionLoginItems,NULL);
    if(!list){fprintf(stderr,"Login-list system API unavailable\n");return 3;}
    int before=count(list,old),existing=count(list,dest);
    printf("old=%d new=%d\n",before,existing);
    if(!strcmp(argv[1],"--inspect"))return before<0?3:0;
    if(before!=1 || existing!=0){fprintf(stderr,"Unexpected target state; no change\n");return 4;}
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)dest,strlen(dest),true);
    CFBundleRef bundle=CFBundleCreate(NULL,url);
    if(!bundle || !CFBundleGetIdentifier(bundle) || !CFEqual(CFBundleGetIdentifier(bundle),CFSTR("local.codex.quota-bar"))){fprintf(stderr,"Target identity mismatch\n");return 5;}
    LSSharedFileListItemRef inserted=LSSharedFileListInsertItemURL(list,kLSSharedFileListItemLast,(CFStringRef)CFBundleGetValueForInfoDictionaryKey(bundle,CFSTR("CFBundleDisplayName")),NULL,url,NULL,NULL);
    if(!inserted || count(list,dest)!=1){
        // macOS may coalesce entries with the same bundle identity. Replace only
        // the exact old item, with a system-API rollback if new insertion fails.
        if(count(list,old)!=1 || count(list,dest)!=0)return 6;
        CFURLRef oldURL=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)old,strlen(old),true);
        CFArrayRef original=LSSharedFileListCopySnapshot(list,NULL);
        for(CFIndex i=0;i<CFArrayGetCount(original);i++){
            LSSharedFileListItemRef item=(LSSharedFileListItemRef)CFArrayGetValueAtIndex(original,i);
            if(matches(item,old) && LSSharedFileListItemRemove(list,item)!=0)return 7;
        }
        if(count(list,old)!=0)return 7;
        inserted=LSSharedFileListInsertItemURL(list,kLSSharedFileListItemLast,(CFStringRef)CFBundleGetValueForInfoDictionaryKey(bundle,CFSTR("CFBundleDisplayName")),NULL,url,NULL,NULL);
        if(!inserted || count(list,dest)!=1){
            LSSharedFileListInsertItemURL(list,kLSSharedFileListItemLast,NULL,NULL,oldURL,NULL,NULL);
            fprintf(stderr,"Replacement failed; rollback old=%d new=%d\n",count(list,old),count(list,dest));
            return 9;
        }
        printf("Replaced coalesced assistant entry through system API\n");
    }
    CFArrayRef items=LSSharedFileListCopySnapshot(list,NULL);
    for(CFIndex i=0;i<CFArrayGetCount(items);i++){
        LSSharedFileListItemRef item=(LSSharedFileListItemRef)CFArrayGetValueAtIndex(items,i);
        if(matches(item,old)){
            OSStatus result=LSSharedFileListItemRemove(list,item);
            if(result){fprintf(stderr,"Removal failed: %d; old login retained\n",(int)result);return 7;}
        }
    }
    printf("verified old=%d new=%d\n",count(list,old),count(list,dest));
    return count(list,old)==0 && count(list,dest)==1 ? 0 : 8;
}
