//
//  FMDatabaseAdditions.m
//  fmdb
//
//  Created by August Mueller on 10/30/05.
//  Copyright 2005 Flying Meat Inc.. All rights reserved.
//

#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"
#import "TargetConditionals.h"

#if FMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else
#import <sqlite3.h>
#endif

@interface FMDatabase (PrivateStuff)
- (FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray * _Nullable)arrayArgs orDictionary:(NSDictionary * _Nullable)dictionaryArgs orVAList:(va_list)args;
@end

@implementation FMDatabase (FMDatabaseAdditions)

#define RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(type, sel)             \
va_list args;                                                        \
va_start(args, query);                                               \
FMResultSet *resultSet = [self executeQuery:query withArgumentsInArray:0x00 orDictionary:0x00 orVAList:args];   \
va_end(args);                                                        \
if (![resultSet next]) { return (type)0; }                           \
type ret = [resultSet sel:0];                                        \
[resultSet close];                                                   \
[resultSet setParentDB:nil];                                         \
return ret;


- (NSString *)stringForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(NSString *, stringForColumnIndex);
}

- (int)intForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(int, intForColumnIndex);
}

- (long)longForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(long, longForColumnIndex);
}

- (BOOL)boolForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(BOOL, boolForColumnIndex);
}

- (double)doubleForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(double, doubleForColumnIndex);
}

- (NSData*)dataForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(NSData *, dataForColumnIndex);
}

- (NSDate*)dateForQuery:(NSString*)query, ... {
    RETURN_RESULT_FOR_QUERY_WITH_SELECTOR(NSDate *, dateForColumnIndex);
}

/** 判断表是否存在 */
- (BOOL)tableExists:(NSString*)tableName {
    tableName = [tableName lowercaseString];
    FMResultSet *rs = [self executeQuery:@"select [sql] from sqlite_master where [type] = 'table' and lower(name) = ?", tableName];
    BOOL returnBool = [rs next];
    [rs close];
    return returnBool;
}

/** 查询数据库中：所有表的一些简要信息
 * 对于表来说， tbl_name 是表名。
 * 但 sqlite_master 中不仅可以是表对象，还可以是其它对象，
 * 比如索引： name 是索引的名字，而 tbl_name 是索引所属的表名
*/
- (FMResultSet * _Nullable)getSchema{
    FMResultSet *rs = [self executeQuery:@"SELECT type, name, tbl_name, rootpage, sql FROM (SELECT * FROM sqlite_master UNION ALL SELECT * FROM sqlite_temp_master) WHERE type != 'meta' AND name NOT LIKE 'sqlite_%' ORDER BY tbl_name, type DESC, name"];
    return rs;
}

/** get table schema: result colums: cid[INTEGER], name,type [STRING], notnull[INTEGER], dflt_value[],pk[INTEGER]
 
 
table_info(
    cid  integer,//列码
    name text,//该列表头
    type text,//该列的数据类性
    pk    boolean,//是否是主键
    notnull boolean,//要求非空
    dflt_value,//该列默认值
)
 */
- (FMResultSet * _Nullable)getTableSchema:(NSString*)tableName {
    //result colums: cid[INTEGER], name,type [STRING], notnull[INTEGER], dflt_value[],pk[INTEGER]
    FMResultSet *rs = [self executeQuery:[NSString stringWithFormat: @"pragma table_info('%@')", tableName]];
    return rs;
}

/** 判断column是否存在
 */
- (BOOL)columnExists:(NSString*)columnName inTableWithName:(NSString*)tableName {
    BOOL returnBool = NO;
    
    tableName  = [tableName lowercaseString];
    columnName = [columnName lowercaseString];
    
    FMResultSet *rs = [self getTableSchema:tableName];//获取 table_info
    
    //check if column is present in table schema
    while ([rs next]) {
        if ([[[rs stringForColumn:@"name"] lowercaseString] isEqualToString:columnName]) {
            returnBool = YES;
            break;
        }
    }
    
    //If this is not done FMDatabase instance stays out of pool
    [rs close];
    return returnBool;
}



- (uint32_t)applicationID {
#if SQLITE_VERSION_NUMBER >= 3007017
    uint32_t r = 0;
    FMResultSet *rs = [self executeQuery:@"pragma application_id"];
    if ([rs next]) {
        r = (uint32_t)[rs longLongIntForColumnIndex:0];
    }
    [rs close];
    return r;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Application ID functions require SQLite 3.7.17", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return 0;
#endif
}

- (void)setApplicationID:(uint32_t)appID {
#if SQLITE_VERSION_NUMBER >= 3007017
    NSString *query = [NSString stringWithFormat:@"pragma application_id=%d", appID];
    FMResultSet *rs = [self executeQuery:query];
    [rs next];
    [rs close];
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Application ID functions require SQLite 3.7.17", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
#endif
}


#if TARGET_OS_MAC && !TARGET_OS_IPHONE

- (NSString*)applicationIDString {
#if SQLITE_VERSION_NUMBER >= 3007017
    NSString *s = NSFileTypeForHFSTypeCode([self applicationID]);
    
    assert([s length] == 6);
    
    s = [s substringWithRange:NSMakeRange(1, 4)];
    
    
    return s;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Application ID functions require SQLite 3.7.17", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return nil;
#endif
}

- (void)setApplicationIDString:(NSString*)s {
#if SQLITE_VERSION_NUMBER >= 3007017
    if ([s length] != 4) {
        NSLog(@"setApplicationIDString: string passed is not exactly 4 chars long. (was %ld)", [s length]);
    }
    
    [self setApplicationID:NSHFSTypeCodeFromFileType([NSString stringWithFormat:@"'%@'", s])];
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Application ID functions require SQLite 3.7.17", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
#endif
}

#endif

/** 检索用户版本
 */
- (uint32_t)userVersion {
    uint32_t r = 0;
    FMResultSet *rs = [self executeQuery:@"pragma user_version"];
    if ([rs next]) {
        r = (uint32_t)[rs longLongIntForColumnIndex:0];
    }
    [rs close];
    return r;
}

- (void)setUserVersion:(uint32_t)version {
    NSString *query = [NSString stringWithFormat:@"pragma user_version = %d", version];
    FMResultSet *rs = [self executeQuery:query];
    [rs next];
    [rs close];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

- (BOOL)columnExists:(NSString*)tableName columnName:(NSString*)columnName __attribute__ ((deprecated)) {
    return [self columnExists:columnName inTableWithName:tableName];
}

#pragma clang diagnostic pop

/** 校验sql语句是否合法
 */
- (BOOL)validateSQL:(NSString*)sql error:(NSError * _Nullable __autoreleasing *)error {
    sqlite3_stmt *pStmt = NULL;
    BOOL validationSucceeded = YES;
    
    int rc = sqlite3_prepare_v2([self sqliteHandle], [sql UTF8String], -1, &pStmt, 0);
    if (rc != SQLITE_OK) {
        validationSucceeded = NO;
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:[self lastErrorCode]
                                     userInfo:[NSDictionary dictionaryWithObject:[self lastErrorMessage] forKey:NSLocalizedDescriptionKey]];
        }
    }
    sqlite3_finalize(pStmt);
    return validationSucceeded;
}

@end
