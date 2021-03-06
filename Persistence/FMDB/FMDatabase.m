#import "FMDatabase.h"
#import <unistd.h>
#import <objc/runtime.h>

#if FMDB_SQLITE_STANDALONE
#import <sqlite3/sqlite3.h>
#else
#import <sqlite3.h>
#endif

@interface FMDatabase ()

{
    void*               _db;//打开的SQLite数据库
    BOOL                _isExecutingStatement;//是否正在执行 Sql 语句
    NSTimeInterval      _startBusyRetryTime;
    
    NSMutableSet        *_openResultSets;
    NSMutableSet        *_openFunctions;
    
    NSDateFormatter     *_dateFormat;
}

NS_ASSUME_NONNULL_BEGIN

- (FMResultSet * _Nullable)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray * _Nullable)arrayArgs orDictionary:(NSDictionary * _Nullable)dictionaryArgs orVAList:(va_list)args;
- (BOOL)executeUpdate:(NSString *)sql error:(NSError * _Nullable __autoreleasing *)outErr withArgumentsInArray:(NSArray * _Nullable)arrayArgs orDictionary:(NSDictionary * _Nullable)dictionaryArgs orVAList:(va_list)args;

NS_ASSUME_NONNULL_END

@end

@implementation FMDatabase

@synthesize shouldCacheStatements = _shouldCacheStatements;
@synthesize maxBusyRetryTimeInterval = _maxBusyRetryTimeInterval;

#pragma mark FMDatabase 实例化、释放

/** FMDBReturnAutoReleased() 是为了兼容MRC和ARC
 * FMDatabase 实例化 本质上只是给了数据库一个名字，并没有真实创建或者获取数据库。
 * -open 方法才是真正获取到数据库，其本质调用SQLite的 sqlite3_open() 函数
 */
+ (instancetype)databaseWithPath:(NSString *)aPath {
    return FMDBReturnAutoreleased([[self alloc] initWithPath:aPath]);
}

+ (instancetype)databaseWithURL:(NSURL *)url {
    return FMDBReturnAutoreleased([[self alloc] initWithURL:url]);
}

- (instancetype)init {
    return [self initWithPath:nil];
}

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithPath:url.path];
}

- (instancetype)initWithPath:(NSString *)path {
    assert(sqlite3_threadsafe());
    self = [super init];
    if (self) {
        _databasePath               = [path copy];
        _openResultSets             = [[NSMutableSet alloc] init];
        _db                         = nil;//数据库为空
        _logsErrors                 = YES;
        _crashOnErrors              = NO;
        _maxBusyRetryTimeInterval   = 2;//默认为 2S
        _isOpen                     = NO;//默认数据库关闭
    }
    return self;
}

#if ! __has_feature(objc_arc)
- (void)finalize {
    [self close];
    [super finalize];
}
#endif

- (void)dealloc {
    [self close];
    FMDBRelease(_openResultSets);
    FMDBRelease(_cachedStatements);
    FMDBRelease(_dateFormat);
    FMDBRelease(_databasePath);
    FMDBRelease(_openFunctions);
    
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

- (NSURL *)databaseURL {
    return _databasePath ? [NSURL fileURLWithPath:_databasePath] : nil;
}

+ (NSString*)FMDBUserVersion {
    return @"2.7.6";
}

/** FMDBVersion 版本号 **/
+ (SInt32)FMDBVersion {
    static dispatch_once_t once;
    static SInt32 FMDBVersionVal = 0;
    dispatch_once(&once, ^{
        NSString *prodVersion = [self FMDBUserVersion];
        if ([[prodVersion componentsSeparatedByString:@"."] count] < 3) {
            prodVersion = [prodVersion stringByAppendingString:@".0"];
        }
        NSString *junk = [prodVersion stringByReplacingOccurrencesOfString:@"." withString:@""];
        char *e = nil;
        FMDBVersionVal = (int) strtoul([junk UTF8String], &e, 16);
    });
    return FMDBVersionVal;
}

/**************  SQLite 信息  **************/
+ (NSString*)sqliteLibVersion {
    return [NSString stringWithFormat:@"%s", sqlite3_libversion()];
}

+ (BOOL)isSQLiteThreadSafe {
    // make sure to read the sqlite headers on this guy!
    return sqlite3_threadsafe() != 0;
}

- (void*)sqliteHandle {
    return _db;
}

/** 如果 filename 参数是 NULL 或 ':memory:'，那么 sqlite3_open() 将会在 RAM 中创建一个内存数据库，这只会在 session 的有效时间内持续。
 */
- (const char*)sqlitePath {
    if (!_databasePath) {
        return ":memory:";// sqlite3_open() 将会在 RAM 中创建一个内存数据库,这只会在 session 的有效时间内持续。
    }
    if ([_databasePath length] == 0) {
        return ""; //这会在 tmp 创建一个数据库
    }
    return [_databasePath fileSystemRepresentation];
}

#pragma mark 打开、关闭 数据库

/** 根据指定路径打开一个 SQLite 数据库，返回一个用于其他 SQLite 程序的数据库连接对象
 * @param filename UTF-8编码的数据库名称
 * @param ppDb SQLite数据库连接对象
int sqlite3_open(const char *filename,sqlite3 **ppDb);
 */

/** 打开数据库打开 : 对 SQLite 中 sqlite3_open() 函数的封装使用
 * 数据库打开后根据 _maxBusyRetryTimeInterval 将数据库线程停顿一段时间，然后继续向下执行
 */
- (BOOL)open {
    if (_isOpen) {
        return YES;
    }
    if (_db) {// 如果之前尝试打开但失败，请确保在再次尝试之前关闭它
        [self close];
    }
    
    /***** 创建数据库 ****/
    int err = sqlite3_open([self sqlitePath], (sqlite3**)&_db);
    if(err != SQLITE_OK) {
        NSLog(@"error opening!: %d", err);
        return NO;
    }
    
    //当执行这段代码的时候，数据库正在被其他线程访问，那我们就需要给他设置一个重试时间，默认为2秒。
    if (_maxBusyRetryTimeInterval > 0.0) {
        [self setMaxBusyRetryTimeInterval:_maxBusyRetryTimeInterval];
    }
    _isOpen = YES;
    return YES;
}

- (BOOL)openWithFlags:(int)flags {
    return [self openWithFlags:flags vfs:nil];
}

- (BOOL)openWithFlags:(int)flags vfs:(NSString *)vfsName {
#if SQLITE_VERSION_NUMBER >= 3005000
    if (_isOpen) {
        return YES;
    }
    if (_db) {// 如果之前尝试打开但失败，请确保在再次尝试之前关闭它
        [self close];
    }
        
    int err = sqlite3_open_v2([self sqlitePath], (sqlite3**)&_db, flags, [vfsName UTF8String]);
    if(err != SQLITE_OK) {
        NSLog(@"error opening!: %d", err);
        return NO;
    }
    if (_maxBusyRetryTimeInterval > 0.0) {
        [self setMaxBusyRetryTimeInterval:_maxBusyRetryTimeInterval];
    }
    _isOpen = YES;
    return YES;
#else
    NSLog(@"openWithFlags requires SQLite 3.5");
    return NO;
#endif
}

/** 关闭数据库连接 */
- (BOOL)close {
    [self clearCachedStatements];//清理缓存
    [self closeOpenResultSets];//清理结果集
    if (!_db) {//如果数据库不存在
        return YES;
    }
    
    int  rc;
    BOOL retry;
    BOOL triedFinalizingOpenStatements = NO;
    do {
        retry   = NO;
        rc      = sqlite3_close(_db);
        if (SQLITE_BUSY == rc || SQLITE_LOCKED == rc) {
            if (!triedFinalizingOpenStatements) {
                triedFinalizingOpenStatements = YES;
                sqlite3_stmt *pStmt;
                while ((pStmt = sqlite3_next_stmt(_db, nil)) !=0) {
                    NSLog(@"Closing leaked statement");
                    sqlite3_finalize(pStmt);
                    retry = YES;
                }
            }
        }else if (SQLITE_OK != rc) {
            NSLog(@"error closing!: %d", rc);
        }
    }
    while (retry);
    _db = nil;//数据库指针指向 nil
    _isOpen = false;//状态改为 NO
    return YES;
}

#pragma mark Busy handler routines

// NOTE: appledoc seems to choke on this function for some reason;
//       so when generating documentation, you might want to ignore the
//       .m files so that it only documents the public interfaces outlined
//       in the .h files.
//
//       This is a known appledoc bug that it has problems with C functions
//       within a class implementation, but for some reason, only this
//       C function causes problems; the rest don't. Anyway, ignoring the .m
//       files with appledoc will prevent this problem from occurring.

/** 该函数就是简单调用 sqlite3_sleep() 来挂起线程
 * @param count 表示这次锁事件，该回调函数被调用的次数。
 * @return 如果返回０时，将不再尝试再次访问数据库而返回SQLITE_BUSY或者SQLITE_IOERR_BLOCKED。
 *         如果回调函数返回非０,　将会不断尝试操作数据库。
 */
static int FMDBDatabaseBusyHandler(void *f, int count) {
    FMDatabase *self = (__bridge FMDatabase*)f;
    if (count == 0) {// count为0，表示第一次执行回调函数
        self->_startBusyRetryTime = [NSDate timeIntervalSinceReferenceDate];//以2001/01/01 GMT为基准时间，返回实例保存的时间与2001/01/01 GMT的时间间隔
        return 1;
    }
    
    // 使用delta变量控制执行回调函数的次数，每次挂起50~100ms
    // 所以maxBusyRetryTimeInterval的作用就在这体现出来了
    // 当挂起的时长大于maxBusyRetryTimeInterval，就返回0，并停止执行该回调函数了
    NSTimeInterval delta = [NSDate timeIntervalSinceReferenceDate] - (self->_startBusyRetryTime);
    
    if (delta < [self maxBusyRetryTimeInterval]) {
        
        // 使用sqlite3_sleep每次当前线程挂起50~100ms
        int requestedSleepInMillseconds = (int) arc4random_uniform(50) + 50;
        int actualSleepInMilliseconds = sqlite3_sleep(requestedSleepInMillseconds);
        
        // 如果实际挂起的时长与想要挂起的时长不一致，可能是因为构建SQLite时没将HAVE_USLEEP置为1
        if (actualSleepInMilliseconds != requestedSleepInMillseconds) {
            NSLog(@"WARNING: Requested sleep of %i milliseconds, but SQLite returned %i. Maybe SQLite wasn't built with HAVE_USLEEP=1?", requestedSleepInMillseconds, actualSleepInMilliseconds);
        }
        return 1;
    }
    
    return 0;
}

/** 最大繁忙重试时间间隔
 *
 * 程序运行过程中，如果有其它线程在读写数据库，那么sqlite3_busy_handler() 会不断调用回调函数，直到其他进程或者线程释放锁。
 * 获得锁之后，不会再调用回调函数，从而向下执行，进行数据库操作。
 * 该函数是在获取不到锁的时候，以执行回调函数的次数来进行延迟，等待其他进程或者线程操作数据库结束，从而获得锁操作数据库。
 *
 *
 * SQLITE_API int sqlite3_busy_handler(sqlite3*,int(*)(void*,int),void*);
 * param1 告知哪个数据库需要设置 busy_handler
 * param2 回调函数，该函数的参数是sqlite3_busy_handler()第三个参数
 * param3 int参数代表锁事件，该函数被调用次数，如果返回为0，不会再次访问数据库，返回非0，将不断尝试访问数据库。
 * 当获取不到锁时，会执行回调函数的次数以此来延时，等待其他线程等操作完数据库，这样获得操作数据库。
 */
- (void)setMaxBusyRetryTimeInterval:(NSTimeInterval)timeout {
    _maxBusyRetryTimeInterval = timeout;
    if (!_db) {
        return;
    }
    
    if (timeout > 0) {//处理的 handler 设置为FMDBDatabaseBusyHandler() 函数
        sqlite3_busy_handler(_db, &FMDBDatabaseBusyHandler, (__bridge void *)(self));
    }else {
        // 不使用任何busy handler处理
        sqlite3_busy_handler(_db, nil, nil);
    }
}

- (NSTimeInterval)maxBusyRetryTimeInterval {
    return _maxBusyRetryTimeInterval;
}


// we no longer make busyRetryTimeout public
// but for folks who don't bother noticing that the interface to FMDatabase changed,
// we'll still implement the method so they don't get suprise crashes
- (int)busyRetryTimeout {
    NSLog(@"%s:%d", __FUNCTION__, __LINE__);
    NSLog(@"FMDB: busyRetryTimeout no longer works, please use maxBusyRetryTimeInterval");
    return -1;
}

- (void)setBusyRetryTimeout:(int)i {
#pragma unused(i)
    NSLog(@"%s:%d", __FUNCTION__, __LINE__);
    NSLog(@"FMDB: setBusyRetryTimeout does nothing, please use setMaxBusyRetryTimeInterval:");
}

#pragma mark 结果集

/** 是否有打开的结果集 ***/
- (BOOL)hasOpenResultSets {
    return [_openResultSets count] > 0;
}

/** 关闭结所有打开的结果集 ***/
- (void)closeOpenResultSets {
    NSSet *openSetCopy = FMDBReturnAutoreleased([_openResultSets copy]);
    for (NSValue *rsInWrappedInATastyValueMeal in openSetCopy) {
        FMResultSet *rs = (FMResultSet *)[rsInWrappedInATastyValueMeal pointerValue];
        [rs setParentDB:nil];
        [rs close];
        [_openResultSets removeObject:rsInWrappedInATastyValueMeal];
    }
}


/** FMResultSet 关闭时，需要FMDatabase从 _openResultSets 移除该结果集 */
- (void)resultSetDidClose:(FMResultSet *)resultSet {
    NSValue *setValue = [NSValue valueWithNonretainedObject:resultSet];
    [_openResultSets removeObject:setValue];
}

#pragma mark 缓存语句

/** 清除缓存语句 */
- (void)clearCachedStatements {
    /** 1、首先遍历字典，将 FMStatement 持有的 sqlite3_stmt 全部释放 */
    for (NSMutableSet *statements in [_cachedStatements objectEnumerator]) {
        for (FMStatement *statement in [statements allObjects]) {
            [statement close];//释放 sqlite3_stmt
        }
    }
    
    /** 2、其次将字典中的元素全部移除 */
    [_cachedStatements removeAllObjects];
}

/** 查询缓存语句 */
- (FMStatement*)cachedStatementForQuery:(NSString*)query {
    NSMutableSet* statements = [_cachedStatements objectForKey:query];
    return [[statements objectsPassingTest:^BOOL(FMStatement* statement, BOOL *stop) {
        *stop = ![statement inUse];
        return *stop;
    }] anyObject];
}

/** 设置缓存语句 */
- (void)setCachedStatement:(FMStatement*)statement forQuery:(NSString*)query {
    NSParameterAssert(query);
    if (!query) {
        NSLog(@"API misuse, -[FMDatabase setCachedStatement:forQuery:] query must not be nil");
        return;
    }
    query = [query copy];
    [statement setQuery:query];
    NSMutableSet* statements = [_cachedStatements objectForKey:query];
    if (!statements) {
        statements = [NSMutableSet set];
    }
    [statements addObject:statement];
    [_cachedStatements setObject:statements forKey:query];
    FMDBRelease(query);
}

#pragma mark 数据库加密

/** 重置加密密钥 */
- (BOOL)rekey:(NSString*)key {
    NSData *keyData = [NSData dataWithBytes:(void *)[key UTF8String] length:(NSUInteger)strlen([key UTF8String])];
    return [self rekeyWithData:keyData];
}

/** 使用 keyData 重置加密密钥 */
- (BOOL)rekeyWithData:(NSData *)keyData {
#ifdef SQLITE_HAS_CODEC
    if (!keyData) {
        return NO;
    }
    
    int rc = sqlite3_rekey(_db, [keyData bytes], (int)[keyData length]);
    
    if (rc != SQLITE_OK) {
        NSLog(@"error on rekey: %d", rc);
        NSLog(@"%@", [self lastErrorMessage]);
    }
    
    return (rc == SQLITE_OK);
#else
#pragma unused(keyData)
    return NO;
#endif
}

/** 设置加密密钥 */
- (BOOL)setKey:(NSString*)key {
    NSData *keyData = [NSData dataWithBytes:[key UTF8String] length:(NSUInteger)strlen([key UTF8String])];
    return [self setKeyWithData:keyData];
}

/** 使用 keyData 设置加密密钥 */
- (BOOL)setKeyWithData:(NSData *)keyData {
#ifdef SQLITE_HAS_CODEC
    if (!keyData) {
        return NO;
    }
    int rc = sqlite3_key(_db, [keyData bytes], (int)[keyData length]);
    return (rc == SQLITE_OK);
#else
#pragma unused(keyData)
    return NO;
#endif
}

#pragma mark 日期格式化

+ (NSDateFormatter *)storeableDateFormat:(NSString *)format {
    NSDateFormatter *result = FMDBReturnAutoreleased([[NSDateFormatter alloc] init]);
    result.dateFormat = format;
    result.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    result.locale = FMDBReturnAutoreleased([[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]);
    return result;
}

- (BOOL)hasDateFormatter {
    return _dateFormat != nil;
}

- (void)setDateFormat:(NSDateFormatter *)format {
    FMDBAutorelease(_dateFormat);
    _dateFormat = FMDBReturnRetained(format);
}

- (NSDate *)dateFromString:(NSString *)s {
    return [_dateFormat dateFromString:s];
}

- (NSString *)stringFromDate:(NSDate *)date {
    return [_dateFormat stringFromDate:date];
}

#pragma mark 数据库状态

- (BOOL)goodConnection {
    //1、数据库是否打开
    if (!_isOpen) {
        return NO;
    }

    //2、尝试一个简单的 SELECT 语句并确认成功
#ifdef SQLCIPHER_CRYPTO
    FMResultSet *rs = [self executeQuery:@"PRAGMA cipher_version"];
    if ([rs next]) {
        NSLog(@"SQLCipher version: %@", rs.resultDictionary[@"cipher_version"]);
        [rs close];
        return YES;
    }
#else
    FMResultSet *rs = [self executeQuery:@"select name from sqlite_master where type='table'"];
    if (rs) {
        [rs close];
        return YES;
    }
#endif
    return NO;
}

//警告开发者：FMDatabase 正在使用中
- (void)warnInUse {
    NSLog(@"The FMDatabase %@ is currently in use.", self);
    
#ifndef NS_BLOCK_ASSERTIONS
    if (_crashOnErrors) {
        NSAssert(false, @"The FMDatabase %@ is currently in use.", self);
        abort();
    }
#endif
}

//数据库是否存在
- (BOOL)databaseExists {
    if (!_isOpen) {
        NSLog(@"The FMDatabase %@ is not open.", self);
        
#ifndef NS_BLOCK_ASSERTIONS
        if (_crashOnErrors) {
            NSAssert(false, @"The FMDatabase %@ is not open.", self);
            abort();
        }
#endif
        return NO;
    }
    return YES;
}

#pragma mark 错误日志

- (NSString *)lastErrorMessage {
    return [NSString stringWithUTF8String:sqlite3_errmsg(_db)];
}

- (BOOL)hadError {
    int lastErrCode = [self lastErrorCode];
    return (lastErrCode > SQLITE_OK && lastErrCode < SQLITE_ROW);
}

- (int)lastErrorCode {
    return sqlite3_errcode(_db);
}

- (int)lastExtendedErrorCode {
    return sqlite3_extended_errcode(_db);
}

- (NSError*)errorWithMessage:(NSString *)message {
    NSDictionary* errorMessage = [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    return [NSError errorWithDomain:@"FMDatabase" code:sqlite3_errcode(_db) userInfo:errorMessage];
}

- (NSError*)lastError {
    return [self errorWithMessage:[self lastErrorMessage]];
}

#pragma mark 更新语句信息

/** 获取最后插入一行的主键 rowid
 * 通过 sqlite3_last_insert_rowid()  函数实现
 * @note 如果数据库连接上从未发生过成功的 INSERT，则返回 0
 */
- (sqlite_int64)lastInsertRowId {
    if (_isExecutingStatement) {//正在执行 Sql 语句
        [self warnInUse];
        return NO;
    }
    _isExecutingStatement = YES;
    sqlite_int64 ret = sqlite3_last_insert_rowid(_db);
    _isExecutingStatement = NO;
    return ret;
}

/** 前一个 SQL 语句更改了多少行
 * 通过 sqlite3_changes()  函数实现
 * @note 只计算由INSERT、UPDATE或DELETE语句直接指定的更改的数据库行数
*/
- (int)changes {
    if (_isExecutingStatement) {//正在执行 Sql 语句
        [self warnInUse];
        return 0;
    }
    _isExecutingStatement = YES;
    int ret = sqlite3_changes(_db);
    _isExecutingStatement = NO;
    return ret;
}

#pragma mark SQL manipulation

/** 将值 obj 绑定预处理语句 sqlite3_stmt
 * @param obj 待绑定的值
 * @param idx 表中所在列数的索引，需要将 obj 绑定到第几列
 * @parma pStmt 预处理语句，需要将 obj 绑定到该结构上
 *
 * @note SQLite的 Sql 语句通过绑定变量，减少SQL语句被动态解析的次数，从而提高数据查询和数据操作的效率。
 *       要完成该操作，需要使用SQLite提供的 sqlite3_reset() 和 sqlite3_bind_*() 函数
 */
- (void)bindObject:(id)obj toColumn:(int)idx inStatement:(sqlite3_stmt*)pStmt {
    if ((!obj) || ((NSNull *)obj == [NSNull null])) {//obj 为 nil
        sqlite3_bind_null(pStmt, idx);
    }else if ([obj isKindOfClass:[NSData class]]) {//绑定 NSData
        const void *bytes = [obj bytes];
        if (!bytes) {
            // 一个空的 NSData 对象, 即 [NSData data].
            // 不要传递空指针，否则sqlite将绑定一个 SQL NULL 而不是一个blob。
            bytes = "";
        }
        sqlite3_bind_blob(pStmt, idx, bytes, (int)[obj length], SQLITE_STATIC);
    }else if ([obj isKindOfClass:[NSDate class]]) {// NSDate
        if (self.hasDateFormatter)
            sqlite3_bind_text(pStmt, idx, [[self stringFromDate:obj] UTF8String], -1, SQLITE_STATIC);
        else
            sqlite3_bind_double(pStmt, idx, [obj timeIntervalSince1970]);
    }else if ([obj isKindOfClass:[NSNumber class]]) {// NSNumber
        if (strcmp([obj objCType], @encode(char)) == 0) {//char 型
            sqlite3_bind_int(pStmt, idx, [obj charValue]);
        }else if (strcmp([obj objCType], @encode(unsigned char)) == 0) {
            sqlite3_bind_int(pStmt, idx, [obj unsignedCharValue]);
        }else if (strcmp([obj objCType], @encode(short)) == 0) {//short 型
            sqlite3_bind_int(pStmt, idx, [obj shortValue]);
        }else if (strcmp([obj objCType], @encode(unsigned short)) == 0) {
            sqlite3_bind_int(pStmt, idx, [obj unsignedShortValue]);
        }else if (strcmp([obj objCType], @encode(int)) == 0) {//int 型
            sqlite3_bind_int(pStmt, idx, [obj intValue]);
        }else if (strcmp([obj objCType], @encode(unsigned int)) == 0) {
            sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedIntValue]);
        }else if (strcmp([obj objCType], @encode(long)) == 0) {//long 型
            sqlite3_bind_int64(pStmt, idx, [obj longValue]);
        }else if (strcmp([obj objCType], @encode(unsigned long)) == 0) {
            sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongValue]);
        }else if (strcmp([obj objCType], @encode(long long)) == 0) {//long long 型
            sqlite3_bind_int64(pStmt, idx, [obj longLongValue]);
        }else if (strcmp([obj objCType], @encode(unsigned long long)) == 0) {
            sqlite3_bind_int64(pStmt, idx, (long long)[obj unsignedLongLongValue]);
        }else if (strcmp([obj objCType], @encode(float)) == 0) {//float 型
            sqlite3_bind_double(pStmt, idx, [obj floatValue]);
        }else if (strcmp([obj objCType], @encode(double)) == 0) {//double 型
            sqlite3_bind_double(pStmt, idx, [obj doubleValue]);
        }else if (strcmp([obj objCType], @encode(BOOL)) == 0) {//BOOL 型
            sqlite3_bind_int(pStmt, idx, ([obj boolValue] ? 1 : 0));
        }else {//text 型
            sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
        }
    }else {// text
        sqlite3_bind_text(pStmt, idx, [[obj description] UTF8String], -1, SQLITE_STATIC);
    }
}

/**  -executeQueryWithFormat: 和 -executeUpdateWithFormat: 方法 需要将对应字符串处理成相应的 SQL 语句：
 * 针对 [db executeUpdateWithFormat:@"INSERT INTO test (name) VALUES (%@)", @"Gus"];
 * 该方法主要将 -executeUpdateWithFormat: 中的 %s 、%d 、 %@ 等转义序列变为占位符 ? ，然后将 "Gus" 加入到arguments中
 */
- (void)extractSQL:(NSString *)sql argumentsList:(va_list)args intoString:(NSMutableString *)cleanedSQL arguments:(NSMutableArray *)arguments {
    
    NSUInteger length = [sql length];
    unichar last = '\0';
    for (NSUInteger i = 0; i < length; ++i) {
        id arg = nil;
        unichar current = [sql characterAtIndex:i];
        unichar add = current;
        if (last == '%') {
            switch (current) {
                case '@':
                    arg = va_arg(args, id);
                    break;
                case 'c':
                    // warning: second argument to 'va_arg' is of promotable type 'char'; this va_arg has undefined behavior because arguments will be promoted to 'int'
                    arg = [NSString stringWithFormat:@"%c", va_arg(args, int)];
                    break;
                case 's':
                    arg = [NSString stringWithUTF8String:va_arg(args, char*)];
                    break;
                case 'd':
                case 'D':
                case 'i':
                    arg = [NSNumber numberWithInt:va_arg(args, int)];
                    break;
                case 'u':
                case 'U':
                    arg = [NSNumber numberWithUnsignedInt:va_arg(args, unsigned int)];
                    break;
                case 'h':
                    i++;
                    if (i < length && [sql characterAtIndex:i] == 'i') {
                        //  warning: second argument to 'va_arg' is of promotable type 'short'; this va_arg has undefined behavior because arguments will be promoted to 'int'
                        arg = [NSNumber numberWithShort:(short)(va_arg(args, int))];
                    }
                    else if (i < length && [sql characterAtIndex:i] == 'u') {
                        // warning: second argument to 'va_arg' is of promotable type 'unsigned short'; this va_arg has undefined behavior because arguments will be promoted to 'int'
                        arg = [NSNumber numberWithUnsignedShort:(unsigned short)(va_arg(args, uint))];
                    }
                    else {
                        i--;
                    }
                    break;
                case 'q':
                    i++;
                    if (i < length && [sql characterAtIndex:i] == 'i') {
                        arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
                    }
                    else if (i < length && [sql characterAtIndex:i] == 'u') {
                        arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
                    }
                    else {
                        i--;
                    }
                    break;
                case 'f':
                    arg = [NSNumber numberWithDouble:va_arg(args, double)];
                    break;
                case 'g':
                    // warning: second argument to 'va_arg' is of promotable type 'float'; this va_arg has undefined behavior because arguments will be promoted to 'double'
                    arg = [NSNumber numberWithFloat:(float)(va_arg(args, double))];
                    break;
                case 'l':
                    i++;
                    if (i < length) {
                        unichar next = [sql characterAtIndex:i];
                        if (next == 'l') {
                            i++;
                            if (i < length && [sql characterAtIndex:i] == 'd') {
                                //%lld
                                arg = [NSNumber numberWithLongLong:va_arg(args, long long)];
                            }
                            else if (i < length && [sql characterAtIndex:i] == 'u') {
                                //%llu
                                arg = [NSNumber numberWithUnsignedLongLong:va_arg(args, unsigned long long)];
                            }
                            else {
                                i--;
                            }
                        }
                        else if (next == 'd') {
                            //%ld
                            arg = [NSNumber numberWithLong:va_arg(args, long)];
                        }
                        else if (next == 'u') {
                            //%lu
                            arg = [NSNumber numberWithUnsignedLong:va_arg(args, unsigned long)];
                        }
                        else {
                            i--;
                        }
                    }
                    else {
                        i--;
                    }
                    break;
                default:
                    // something else that we can't interpret. just pass it on through like normal
                    break;
            }
        }
        else if (current == '%') {
            // 遇到%，直接跳过
            add = '\0';
        }
        
        if (arg != nil) {
            // 如果arg不为空，表示确定arg是参数，那么就使用 ？替换它，并将其对应参数值arg添加到arguments
            [cleanedSQL appendString:@"?"];
            [arguments addObject:arg];
        }
        else if (add == (unichar)'@' && last == (unichar) '%') {
            // 如果参数格式是 %@，但此时arg是空，那么就替换为NULL
            [cleanedSQL appendFormat:@"NULL"];
        }
        else if (add != '\0') {
            // 如果不是参数，就用原先字符串替换
            [cleanedSQL appendFormat:@"%C", add];
        }
        last = current;
    }
}

#pragma mark 执行查询

- (FMResultSet *)executeQuery:(NSString *)sql withParameterDictionary:(NSDictionary *)arguments {
    return [self executeQuery:sql withArgumentsInArray:nil orDictionary:arguments orVAList:nil];
}

/** 该方法主要做了几件事：
 * 1、判断环境：数据库是否存在、或者是否正在执行 Sql 语句；
 * 2、如果有缓存，则获取缓存，并重置预处理语句 sqlite3_stmt；
 * 3、如果没有缓存，则调用 sqlite3_prepare_v2() 函数创建 sqlite3_stmt；
 * 4、将 Sql 语句中占位符 ？ 所对应的变量值通过  sqlite3_bind_*() 函数绑定到结构 sqlite3_stmt 上；
 * 5、如果 FMStatement 实例为空，则创建 FMStatement 实例，并根据需要缓存该实例；
 * 6、 根据 FMStatement 实例创建一个 FMResultSet ，并将FMResultSet 实例存储在数组 _openResultSets 中；
 */
- (FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args {
    /********** 判断环境 ********/
    if (![self databaseExists]) {//判断数据库是否存在
        return 0x00;
    }
    if (_isExecutingStatement) {//是否正在执行 Sql 语句
        [self warnInUse];
        return 0x00;
    }
    _isExecutingStatement = YES;
    
    int rc                  = 0x00;
    sqlite3_stmt *pStmt     = 0x00;//预处理语句
    FMStatement *statement  = 0x00;//缓存语句
    FMResultSet *rs         = 0x00;//结果集
    
    if (_traceExecution && sql) {//打印sql语句
        NSLog(@"%@ executeQuery: %@", self, sql);
    }
    /********** 获取缓存数据 ********/
    if (_shouldCacheStatements) {
        statement = [self cachedStatementForQuery:sql];
        pStmt = statement ? [statement statement] : 0x00;//缓存的预处理语句
        [statement reset];
    }
        
    /********** 没有缓存则调用 sqlite3_prepare() 创建 sqlite3_stmt ********/
    if (!pStmt) {
        //对sql语句进行预处理，创建 sqlite3_stmt
        rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &pStmt, 0);
        if (SQLITE_OK != rc) {//错误处理
            if (_logsErrors) {
                NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                NSLog(@"DB Query: %@", sql);
                NSLog(@"DB Path: %@", _databasePath);
            }
            if (_crashOnErrors) {
                NSAssert(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                abort();
            }
            sqlite3_finalize(pStmt);
            _isExecutingStatement = NO;
            return nil;
        }
    }
    
    /********** 将变量绑定到 sqlite3_stmt 上 ********/
    id obj;
    int idx = 0;
    int queryCount = sqlite3_bind_parameter_count(pStmt);
    if (dictionaryArgs) {
        for (NSString *dictionaryKey in [dictionaryArgs allKeys]) {
            NSString *parameterName = [[NSString alloc] initWithFormat:@":%@", dictionaryKey];
            if (_traceExecution) {
                NSLog(@"%@ = %@", parameterName, [dictionaryArgs objectForKey:dictionaryKey]);
            }
            // 获取参数名的索引： 第几列
            int namedIdx = sqlite3_bind_parameter_index(pStmt, [parameterName UTF8String]);
            FMDBRelease(parameterName);
            if (namedIdx > 0) {
                // 将指定的 value 绑定到 sqlite3_stmt 上 指定的列数
                [self bindObject:[dictionaryArgs objectForKey:dictionaryKey] toColumn:namedIdx inStatement:pStmt];
                idx++;//计量绑定的参数
            }else {
                NSLog(@"Could not find index for %@", dictionaryKey);
            }
        }
    } else {//对于arrayArgs参数和不定参数的处理，类似于"?"参数形式
        while (idx < queryCount) {
            if (arrayArgs && idx < (int)[arrayArgs count]) {
                obj = [arrayArgs objectAtIndex:(NSUInteger)idx];
            }else if (args) {//不定参数形式
                obj = va_arg(args, id);
            }else {
                break;
            }
            if (_traceExecution) {
                if ([obj isKindOfClass:[NSData class]]) {
                    NSLog(@"data: %ld bytes", (unsigned long)[(NSData*)obj length]);
                }
                else {
                    NSLog(@"obj: %@", obj);
                }
            }
            idx++;//计量绑定的参数
            // 将指定的 value 绑定到 sqlite3_stmt 上 指定的列数
            [self bindObject:obj toColumn:idx inStatement:pStmt];
        }
    }
    if (idx != queryCount) {//如果绑定的参数数目不对，则进行出错处理
        NSLog(@"Error: the bind count is not correct for the # of variables (executeQuery)");
        sqlite3_finalize(pStmt);
        _isExecutingStatement = NO;
        return nil;
    }
    FMDBRetain(statement);
    
    /********** 没有 FMStatement 则创建 FMStatement 对象  ********/
    if (!statement) {
        statement = [[FMStatement alloc] init];
        [statement setStatement:pStmt];
        if (_shouldCacheStatements && sql) {
            //缓存的处理，key为sql语句，值为statement
            [self setCachedStatement:statement forQuery:sql];
        }
    }
    
    /*************** 根据 FMStatement 实例创建一个 FMResultSet *************/
    rs = [FMResultSet resultSetWithStatement:statement usingParentDatabase:self];
    [rs setQuery:sql];
    
    NSValue *openResultSet = [NSValue valueWithNonretainedObject:rs];
    [_openResultSets addObject:openResultSet];
    [statement setUseCount:[statement useCount] + 1];
    FMDBRelease(statement);
    _isExecutingStatement = NO;
    return rs;
}

- (FMResultSet *)executeQuery:(NSString*)sql, ... {
    va_list args;
    va_start(args, sql);
    id result = [self executeQuery:sql withArgumentsInArray:nil orDictionary:nil orVAList:args];
    va_end(args);
    return result;
}

- (FMResultSet *)executeQueryWithFormat:(NSString*)format, ... {
    va_list args;
    va_start(args, format);
    NSMutableString *sql = [NSMutableString stringWithCapacity:[format length]];
    NSMutableArray *arguments = [NSMutableArray array];
    [self extractSQL:format argumentsList:args intoString:sql arguments:arguments];
    va_end(args);
    return [self executeQuery:sql withArgumentsInArray:arguments];
}

- (FMResultSet *)executeQuery:(NSString *)sql withArgumentsInArray:(NSArray *)arguments {
    return [self executeQuery:sql withArgumentsInArray:arguments orDictionary:nil orVAList:nil];
}

- (FMResultSet *)executeQuery:(NSString *)sql values:(NSArray *)values error:(NSError * __autoreleasing *)error {
    FMResultSet *rs = [self executeQuery:sql withArgumentsInArray:values orDictionary:nil orVAList:nil];
    if (!rs && error) {
        *error = [self lastError];
    }
    return rs;
}

- (FMResultSet *)executeQuery:(NSString*)sql withVAList:(va_list)args {
    return [self executeQuery:sql withArgumentsInArray:nil orDictionary:nil orVAList:args];
}

#pragma mark 执行更新

/** 该方法主要做了几件事：
 * 1、判断环境：数据库是否存在、或者是否正在执行 Sql 语句；
 * 2、如果有缓存，则获取缓存，并重置预处理语句 sqlite3_stmt；
 * 3、如果没有缓存，则调用 sqlite3_prepare_v2() 函数创建 sqlite3_stmt；
 * 4、将 Sql 语句中占位符 ？ 所对应的变量值通过  sqlite3_bind_*() 函数绑定到结构 sqlite3_stmt 上；
 * 5、调用 sqlite3_step() 函数执行预处理语句 sqlite3_stmt；
 * 6、针对缓存的处理：如果需要则缓存，否则释放预处理语句 sqlite3_stmt；
 */
- (BOOL)executeUpdate:(NSString*)sql error:(NSError * _Nullable __autoreleasing *)outErr withArgumentsInArray:(NSArray*)arrayArgs orDictionary:(NSDictionary *)dictionaryArgs orVAList:(va_list)args {
    /********** 判断环境 ********/
    if (![self databaseExists]) {//数据库是否存在
        return NO;
    }
    if (_isExecutingStatement) {//正在执行 Sql
        [self warnInUse];
        return NO;
    }
    _isExecutingStatement = YES;
    
    int rc                   = 0x00;
    sqlite3_stmt *pStmt      = 0x00;//预处理语句
    FMStatement *cachedStmt  = 0x00;//缓存语句
    
    if (_traceExecution && sql) {
        NSLog(@"%@ executeUpdate: %@", self, sql);
    }
    
    /********** 获取缓存数据 ********/
    if (_shouldCacheStatements) {
        cachedStmt = [self cachedStatementForQuery:sql];//取出缓存的 FMStatement
        pStmt = cachedStmt ? [cachedStmt statement] : 0x00;//获取预处理语句 sqlite3_stmt
        [cachedStmt reset];//重置 sqlite3_stmt
    }
    
    /********** 没有缓存则调用 sqlite3_prepare_v2() 创建 sqlite3_stmt ********/
    if (!pStmt) {
        //对sql语句进行编译，创建 sqlite3_stmt
        rc = sqlite3_prepare_v2(_db, [sql UTF8String], -1, &pStmt, 0);
        if (SQLITE_OK != rc) {
            if (_logsErrors) {
                NSLog(@"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                NSLog(@"DB Query: %@", sql);
                NSLog(@"DB Path: %@", _databasePath);
            }
            if (_crashOnErrors) {
                NSAssert(false, @"DB Error: %d \"%@\"", [self lastErrorCode], [self lastErrorMessage]);
                abort();
            }
            if (outErr) {
                *outErr = [self errorWithMessage:[NSString stringWithUTF8String:sqlite3_errmsg(_db)]];
            }
            sqlite3_finalize(pStmt);//失败则释放 sqlite3_stmt
            _isExecutingStatement = NO;
            return NO;
        }
    }
    
    /********** 将变量绑定到 sqlite3_stmt 上 ********/
    id obj;
    int idx = 0;
    int queryCount = sqlite3_bind_parameter_count(pStmt);
    if (dictionaryArgs) {
        for (NSString *dictionaryKey in [dictionaryArgs allKeys]) {
            NSString *parameterName = [[NSString alloc] initWithFormat:@":%@", dictionaryKey];
            if (_traceExecution) {
                NSLog(@"%@ = %@", parameterName, [dictionaryArgs objectForKey:dictionaryKey]);
            }
             // 获取参数名的索引： 第几列
            int namedIdx = sqlite3_bind_parameter_index(pStmt, [parameterName UTF8String]);
            FMDBRelease(parameterName);
            if (namedIdx > 0) {
                // 将指定的 value 绑定到 sqlite3_stmt 上 指定的列数
                [self bindObject:[dictionaryArgs objectForKey:dictionaryKey] toColumn:namedIdx inStatement:pStmt];
                idx++;// 计量绑定的参数
            }else {
                NSString *message = [NSString stringWithFormat:@"Could not find index for %@", dictionaryKey];
                if (_logsErrors) {
                    NSLog(@"%@", message);
                }
                if (outErr) {
                    *outErr = [self errorWithMessage:message];
                }
            }
        }
    }else {
        while (idx < queryCount) {
            if (arrayArgs && idx < (int)[arrayArgs count]) {
                obj = [arrayArgs objectAtIndex:(NSUInteger)idx];
            }else if (args) {
                obj = va_arg(args, id);
            }else {
                //We ran out of arguments
                break;
            }
            
            if (_traceExecution) {
                if ([obj isKindOfClass:[NSData class]]) {
                    NSLog(@"data: %ld bytes", (unsigned long)[(NSData*)obj length]);
                }
                else {
                    NSLog(@"obj: %@", obj);
                }
            }
            idx++;// 计量绑定的参数
            // 将指定的 value 绑定到 sqlite3_stmt 上 指定的列数
            [self bindObject:obj toColumn:idx inStatement:pStmt];
        }
    }
    if (idx != queryCount) {//如果绑定的参数数目不对，则进行出错处理
        NSString *message = [NSString stringWithFormat:@"Error: the bind count (%d) is not correct for the # of variables in the query (%d) (%@) (executeUpdate)", idx, queryCount, sql];
        if (_logsErrors) {
            NSLog(@"%@", message);
        }
        if (outErr) {
            *outErr = [self errorWithMessage:message];
        }
        
        sqlite3_finalize(pStmt);
        _isExecutingStatement = NO;
        return NO;
    }
    
    /** 用于执行有前面 sqlite3_prepare() 创建的 sqlite3_stmt 语句。
     * 该函数执行到结果的第一行可用的位置,继续前进到结果的第二行的话，只需再次调用sqlite3_setp()。
     * 由于执行的SQL不是 SELECT 语句，假设不会返回任何数据，此处 sqlite3_setp() 只调用一次。
     */
    rc = sqlite3_step(pStmt);//执行预处理语句
    if (SQLITE_DONE == rc) {
        //sqlite3_step() 完成执行操作
    }else if (SQLITE_INTERRUPT == rc) {
        //操作被 sqlite3_interupt() 函数中断
        if (_logsErrors) {
            NSLog(@"Error calling sqlite3_step. Query was interrupted (%d: %s) SQLITE_INTERRUPT", rc, sqlite3_errmsg(_db));
            NSLog(@"DB Query: %@", sql);
        }
    }else if (rc == SQLITE_ROW) {
        // sqlite3_step() 已经产生一个行结果 ： 即 sqlite3_stmt 被执行过了一次
        NSString *message = [NSString stringWithFormat:@"A executeUpdate is being called with a query string '%@'", sql];
        if (_logsErrors) {
            NSLog(@"%@", message);
            NSLog(@"DB Query: %@", sql);
        }
        if (outErr) {
            *outErr = [self errorWithMessage:message];
        }
    }else {
        if (outErr) {
            *outErr = [self errorWithMessage:[NSString stringWithUTF8String:sqlite3_errmsg(_db)]];
        }
        
        if (SQLITE_ERROR == rc) {// SQL错误 或 丢失数据库
            if (_logsErrors) {
                NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_ERROR", rc, sqlite3_errmsg(_db));
                NSLog(@"DB Query: %@", sql);
            }
        }else if (SQLITE_MISUSE == rc) {//不正确的库使用
            if (_logsErrors) {
                NSLog(@"Error calling sqlite3_step (%d: %s) SQLITE_MISUSE", rc, sqlite3_errmsg(_db));
                NSLog(@"DB Query: %@", sql);
            }
        }else {
            if (_logsErrors) {
                NSLog(@"Unknown error calling sqlite3_step (%d: %s) eu", rc, sqlite3_errmsg(_db));
                NSLog(@"DB Query: %@", sql);
            }
        }
    }
    
   
    /**********  针对缓存的处理  ********/
    if (_shouldCacheStatements && !cachedStmt) {//没有缓存，且需要缓存，则创建 FMStatement 对象并缓存
        cachedStmt = [[FMStatement alloc] init];
        [cachedStmt setStatement:pStmt];
        [self setCachedStatement:cachedStmt forQuery:sql];
        FMDBRelease(cachedStmt);
    }
    int closeErrorCode;
    
    if (cachedStmt) {//对缓存数据的处理
        [cachedStmt setUseCount:[cachedStmt useCount] + 1];//计算 sqlite3_stmt 使用过的次数
        closeErrorCode = sqlite3_reset(pStmt);//重置一个pStmt语句对象到它的初始状态，然后准备被重新执行。
    }else {
        //如果不需要缓存，则释放 sqlite3_stmt
        closeErrorCode = sqlite3_finalize(pStmt);
    }
    
    if (closeErrorCode != SQLITE_OK) {
        if (_logsErrors) {
            NSLog(@"Unknown error finalizing or resetting statement (%d: %s)", closeErrorCode, sqlite3_errmsg(_db));
            NSLog(@"DB Query: %@", sql);
        }
    }
    
    _isExecutingStatement = NO;
    return (rc == SQLITE_DONE || rc == SQLITE_OK);
}

- (BOOL)executeUpdate:(NSString*)sql, ... {
    va_list args;
    va_start(args, sql);
    BOOL result = [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:nil orVAList:args];
    va_end(args);
    return result;
}

- (BOOL)executeUpdate:(NSString*)sql withArgumentsInArray:(NSArray *)arguments {
    return [self executeUpdate:sql error:nil withArgumentsInArray:arguments orDictionary:nil orVAList:nil];
}

- (BOOL)executeUpdate:(NSString*)sql values:(NSArray *)values error:(NSError * __autoreleasing *)error {
    return [self executeUpdate:sql error:error withArgumentsInArray:values orDictionary:nil orVAList:nil];
}

- (BOOL)executeUpdate:(NSString*)sql withParameterDictionary:(NSDictionary *)arguments {
    return [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:arguments orVAList:nil];
}

- (BOOL)executeUpdate:(NSString*)sql withVAList:(va_list)args {
    return [self executeUpdate:sql error:nil withArgumentsInArray:nil orDictionary:nil orVAList:args];
}

- (BOOL)executeUpdateWithFormat:(NSString*)format, ... {
    va_list args;
    va_start(args, format);
    NSMutableString *sql      = [NSMutableString stringWithCapacity:[format length]];
    NSMutableArray *arguments = [NSMutableArray array];
    [self extractSQL:format argumentsList:args intoString:sql arguments:arguments];
    va_end(args);
    return [self executeUpdate:sql withArgumentsInArray:arguments];
}


int FMDBExecuteBulkSQLCallback(void *theBlockAsVoid, int columns, char **values, char **names); // shhh clang.
int FMDBExecuteBulkSQLCallback(void *theBlockAsVoid, int columns, char **values, char **names) {
    
    if (!theBlockAsVoid) {
        return SQLITE_OK;
    }
    
    int (^execCallbackBlock)(NSDictionary *resultsDictionary) = (__bridge int (^)(NSDictionary *__strong))(theBlockAsVoid);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:(NSUInteger)columns];
    
    for (NSInteger i = 0; i < columns; i++) {
        NSString *key = [NSString stringWithUTF8String:names[i]];
        id value = values[i] ? [NSString stringWithUTF8String:values[i]] : [NSNull null];
        value = value ? value : [NSNull null];
        [dictionary setObject:value forKey:key];
    }
    
    return execCallbackBlock(dictionary);
}

- (BOOL)executeStatements:(NSString *)sql {
    return [self executeStatements:sql withResultBlock:nil];
}

- (BOOL)executeStatements:(NSString *)sql withResultBlock:(__attribute__((noescape)) FMDBExecuteStatementsCallbackBlock)block {
    
    int rc;
    char *errmsg = nil;
    
    rc = sqlite3_exec([self sqliteHandle], [sql UTF8String], block ? FMDBExecuteBulkSQLCallback : nil, (__bridge void *)(block), &errmsg);
    
    if (errmsg && [self logsErrors]) {
        NSLog(@"Error inserting batch: %s", errmsg);
    }
    if (errmsg) {
        sqlite3_free(errmsg);
    }
    
    return (rc == SQLITE_OK);
}

- (BOOL)executeUpdate:(NSString*)sql withErrorAndBindings:(NSError * _Nullable __autoreleasing *)outErr, ... {
    
    va_list args;
    va_start(args, outErr);
    
    BOOL result = [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:args];
    
    va_end(args);
    return result;
}


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (BOOL)update:(NSString*)sql withErrorAndBindings:(NSError * _Nullable __autoreleasing *)outErr, ... {
    va_list args;
    va_start(args, outErr);
    
    BOOL result = [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:args];
    
    va_end(args);
    return result;
}

#pragma clang diagnostic pop

#pragma mark 事务

//事务回滚
- (BOOL)rollback {
    BOOL b = [self executeUpdate:@"rollback transaction"];
    if (b) {
        _isInTransaction = NO;//标记事务结束
    }
    return b;
}

//事务确认
- (BOOL)commit {
    BOOL b =  [self executeUpdate:@"commit transaction"];
    if (b) {
        _isInTransaction = NO;//标记事务结束
    }
    return b;
}

- (BOOL)beginTransaction {//默认开始互斥事务
    BOOL b = [self executeUpdate:@"begin exclusive transaction"];
    if (b) {
        _isInTransaction = YES;//标记处于事务中
    }
    return b;
}

- (BOOL)beginDeferredTransaction {//开始一个延迟的事务
    BOOL b = [self executeUpdate:@"begin deferred transaction"];
    if (b) {
        _isInTransaction = YES;
    }
    return b;
}

- (BOOL)beginImmediateTransaction {//开启即时事务
    BOOL b = [self executeUpdate:@"begin immediate transaction"];
    if (b) {
        _isInTransaction = YES;
    }
    return b;
}

- (BOOL)beginExclusiveTransaction {//开始互斥事务
    BOOL b = [self executeUpdate:@"begin exclusive transaction"];
    if (b) {
        _isInTransaction = YES;
    }
    return b;
}

- (BOOL)inTransaction {
    return _isInTransaction;
}

/** 中断数据库的所有操作 **/
- (BOOL)interrupt{
    if (_db) {
        sqlite3_interrupt([self sqliteHandle]);
        return YES;
    }
    return NO;
}

//处理 SavePoint 名字中的特殊字符
static NSString *FMDBEscapeSavePointName(NSString *savepointName) {
    return [savepointName stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

// 设置保存点： savepoint a
- (BOOL)startSavePointWithName:(NSString*)name error:(NSError * _Nullable __autoreleasing *)outErr {
#if SQLITE_VERSION_NUMBER >= 3007000
    NSParameterAssert(name);
    
    NSString *sql = [NSString stringWithFormat:@"savepoint '%@';", FMDBEscapeSavePointName(name)];
    
    return [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:nil];
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return NO;
#endif
}

//刪除保存点： release savepoint a
- (BOOL)releaseSavePointWithName:(NSString*)name error:(NSError * _Nullable __autoreleasing *)outErr {
#if SQLITE_VERSION_NUMBER >= 3007000
    NSParameterAssert(name);
    
    NSString *sql = [NSString stringWithFormat:@"release savepoint '%@';", FMDBEscapeSavePointName(name)];

    return [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:nil];
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return NO;
#endif
}

//回滚到保存点：rollback transaction to savepoint a
- (BOOL)rollbackToSavePointWithName:(NSString*)name error:(NSError * _Nullable __autoreleasing *)outErr {
#if SQLITE_VERSION_NUMBER >= 3007000
    NSParameterAssert(name);
    
    NSString *sql = [NSString stringWithFormat:@"rollback transaction to savepoint '%@';", FMDBEscapeSavePointName(name)];

    return [self executeUpdate:sql error:outErr withArgumentsInArray:nil orDictionary:nil orVAList:nil];
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return NO;
#endif
}

/** 执行保存点后的代码
 * @param block 要在保存点内执行的代码块
 * @return 错误对应的NSError；如果没有错误返回nil
*/
- (NSError*)inSavePoint:(__attribute__((noescape)) void (^)(BOOL *rollback))block {
#if SQLITE_VERSION_NUMBER >= 3007000
    static unsigned long savePointIdx = 0;
    
    NSString *name = [NSString stringWithFormat:@"dbSavePoint%ld", savePointIdx++];
    
    BOOL shouldRollback = NO;
    
    NSError *err = 0x00;
    
    if (![self startSavePointWithName:name error:&err]) {
        return err;
    }
    
    if (block) {
        block(&shouldRollback);
    }
    
    if (shouldRollback) {
        // We need to rollback and release this savepoint to remove it
        [self rollbackToSavePointWithName:name error:&err];
    }
    [self releaseSavePointWithName:name error:&err];
    
    return err;
#else
    NSString *errorMessage = NSLocalizedStringFromTable(@"Save point functions require SQLite 3.7", @"FMDB", nil);
    if (self.logsErrors) NSLog(@"%@", errorMessage);
    return [NSError errorWithDomain:@"FMDatabase" code:0 userInfo:@{NSLocalizedDescriptionKey : errorMessage}];
#endif
}

- (BOOL)checkpoint:(FMDBCheckpointMode)checkpointMode error:(NSError * __autoreleasing *)error {
    return [self checkpoint:checkpointMode name:nil logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(FMDBCheckpointMode)checkpointMode name:(NSString *)name error:(NSError * __autoreleasing *)error {
    return [self checkpoint:checkpointMode name:name logFrameCount:NULL checkpointCount:NULL error:error];
}

- (BOOL)checkpoint:(FMDBCheckpointMode)checkpointMode name:(NSString *)name logFrameCount:(int *)logFrameCount checkpointCount:(int *)checkpointCount error:(NSError * __autoreleasing *)error{
    const char* dbName = [name UTF8String];
#if SQLITE_VERSION_NUMBER >= 3007006
    int err = sqlite3_wal_checkpoint_v2(_db, dbName, checkpointMode, logFrameCount, checkpointCount);
#else
    NSLog(@"sqlite3_wal_checkpoint_v2 unavailable before sqlite 3.7.6. Ignoring checkpoint mode: %d", mode);
    int err = sqlite3_wal_checkpoint(_db, dbName);
#endif
    if(err != SQLITE_OK) {
        if (error) {
            *error = [self lastError];
        }
        if (self.logsErrors) NSLog(@"%@", [self lastErrorMessage]);
        if (self.crashOnErrors) {
            NSAssert(false, @"%@", [self lastErrorMessage]);
            abort();
        }
        return NO;
    } else {
        return YES;
    }
}

#pragma mark 缓存Sql

//是否需要缓存
- (BOOL)shouldCacheStatements {
    return _shouldCacheStatements;
}

/** shouldCacheStatements 的 -set 方法
 * 根据情况为字典 cachedStatements 赋值
 */
- (void)setShouldCacheStatements:(BOOL)value {
    _shouldCacheStatements = value;
    if (_shouldCacheStatements && !_cachedStatements) {
        [self setCachedStatements:[NSMutableDictionary dictionary]];
    }
    if (!_shouldCacheStatements) {
        [self setCachedStatements:nil];//清空缓存数据
    }
}

#pragma mark Callback function

void FMDBBlockSQLiteCallBackFunction(sqlite3_context *context, int argc, sqlite3_value **argv); // -Wmissing-prototypes
void FMDBBlockSQLiteCallBackFunction(sqlite3_context *context, int argc, sqlite3_value **argv) {
#if ! __has_feature(objc_arc)
    void (^block)(sqlite3_context *context, int argc, sqlite3_value **argv) = (id)sqlite3_user_data(context);
#else
    void (^block)(sqlite3_context *context, int argc, sqlite3_value **argv) = (__bridge id)sqlite3_user_data(context);
#endif
    if (block) {
        @autoreleasepool {
            block(context, argc, argv);
        }
    }
}

// deprecated because "arguments" parameter is not maximum argument count, but actual argument count.

- (void)makeFunctionNamed:(NSString *)name maximumArguments:(int)arguments withBlock:(void (^)(void *context, int argc, void **argv))block {
    [self makeFunctionNamed:name arguments:arguments block:block];
}

- (void)makeFunctionNamed:(NSString *)name arguments:(int)arguments block:(void (^)(void *context, int argc, void **argv))block {
    
    if (!_openFunctions) {
        _openFunctions = [NSMutableSet new];
    }
    
    id b = FMDBReturnAutoreleased([block copy]);
    
    [_openFunctions addObject:b];
    
    /* I tried adding custom functions to release the block when the connection is destroyed- but they seemed to never be called, so we use _openFunctions to store the values instead. */
#if ! __has_feature(objc_arc)
    sqlite3_create_function([self sqliteHandle], [name UTF8String], arguments, SQLITE_UTF8, (void*)b, &FMDBBlockSQLiteCallBackFunction, 0x00, 0x00);
#else
    sqlite3_create_function([self sqliteHandle], [name UTF8String], arguments, SQLITE_UTF8, (__bridge void*)b, &FMDBBlockSQLiteCallBackFunction, 0x00, 0x00);
#endif
}

- (SqliteValueType)valueType:(void *)value {
    return sqlite3_value_type(value);
}

- (int)valueInt:(void *)value {
    return sqlite3_value_int(value);
}

- (long long)valueLong:(void *)value {
    return sqlite3_value_int64(value);
}

- (double)valueDouble:(void *)value {
    return sqlite3_value_double(value);
}

- (NSData *)valueData:(void *)value {
    const void *bytes = sqlite3_value_blob(value);
    int length = sqlite3_value_bytes(value);
    return bytes ? [NSData dataWithBytes:bytes length:(NSUInteger)length] : nil;
}

- (NSString *)valueString:(void *)value {
    const char *cString = (const char *)sqlite3_value_text(value);
    return cString ? [NSString stringWithUTF8String:cString] : nil;
}

- (void)resultNullInContext:(void *)context {
    sqlite3_result_null(context);
}

- (void)resultInt:(int) value context:(void *)context {
    sqlite3_result_int(context, value);
}

- (void)resultLong:(long long)value context:(void *)context {
    sqlite3_result_int64(context, value);
}

- (void)resultDouble:(double)value context:(void *)context {
    sqlite3_result_double(context, value);
}

- (void)resultData:(NSData *)data context:(void *)context {
    sqlite3_result_blob(context, data.bytes, (int)data.length, SQLITE_TRANSIENT);
}

- (void)resultString:(NSString *)value context:(void *)context {
    sqlite3_result_text(context, [value UTF8String], -1, SQLITE_TRANSIENT);
}

- (void)resultError:(NSString *)error context:(void *)context {
    sqlite3_result_error(context, [error UTF8String], -1);
}

- (void)resultErrorCode:(int)errorCode context:(void *)context {
    sqlite3_result_error_code(context, errorCode);
}

- (void)resultErrorNoMemoryInContext:(void *)context {
    sqlite3_result_error_nomem(context);
}

- (void)resultErrorTooBigInContext:(void *)context {
    sqlite3_result_error_toobig(context);
}

@end



@implementation FMStatement

#if ! __has_feature(objc_arc)
- (void)finalize {
    [self close];
    [super finalize];
}
#endif

- (void)dealloc {
    [self close];
    FMDBRelease(_query);
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)close {
    if (_statement) {
        sqlite3_finalize(_statement);
        _statement = 0x00;
    }
    _inUse = NO;
}

- (void)reset {
    if (_statement) {
        sqlite3_reset(_statement);
    }
    _inUse = NO;
}

- (NSString*)description {
    return [NSString stringWithFormat:@"%@ %ld hit(s) for query %@", [super description], _useCount, _query];
}

@end

