#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
// #import "util.h"

// -------------------- INÍCIO DO SISTEMA DE LOG --------------------
// Função para registrar logs no arquivo
static void vcam_log(NSString *message) {
    // Cria um formatador de data para adicionar timestamp aos logs
    static NSDateFormatter *dateFormatter = nil;
    if (dateFormatter == nil) {
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    }
    
    // Obtém a data e hora atual
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    
    // Formata a mensagem de log com timestamp
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    
    // Caminho para o arquivo de log
    NSString *logPath = @"/tmp/vcam_testeDEBUG.log";
    
    // Verifica se o arquivo existe, se não, cria-o
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    
    // Abre o arquivo em modo de anexação
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

// Função para registrar logs com formato, semelhante a NSLog
static void vcam_logf(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    // Usa a função vcam_log para registrar a mensagem formatada
    vcam_log(message);
}
// -------------------- FIM DO SISTEMA DE LOG --------------------

// Variáveis globais para gerenciamento de recursos
static NSFileManager *g_fileManager = nil; // Objeto para gerenciamento de arquivos
static UIPasteboard *g_pasteboard = nil; // Objeto de acesso à área de transferência
static BOOL g_canReleaseBuffer = YES; // Flag que indica se o buffer pode ser liberado
static BOOL g_bufferReload = YES; // Flag que indica se o vídeo precisa ser recarregado
static AVSampleBufferDisplayLayer *g_previewLayer = nil; // Layer para visualização da câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // Timestamp da última atualização por VideoDataOutput
static BOOL g_cameraRunning = NO; // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B"; // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto

// Caminhos de arquivos usados pelo tweak
NSString *g_isMirroredMark = @"/var/mobile/Library/Caches/vcam_is_mirrored_mark"; // Marca que indica se a imagem deve ser espelhada
NSString *g_tempFile = @"/var/mobile/Library/Caches/temp.mov"; // Arquivo temporário do vídeo de substituição


// Classe para obtenção e manipulação de frames de vídeo
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef) originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
@end

@implementation GetFrame
// Método para obter o frame atual de vídeo
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable) originSampleBuffer :(BOOL)forceReNew{
    vcam_log(@"GetFrame::getCurrentFrame - Início da função");
    
    // Recursos estáticos para reuso entre chamadas
    static AVAssetReader *reader = nil;
    static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
    static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
    static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
    static CMSampleBufferRef sampleBuffer = nil;

    // Informações do buffer original
    CMFormatDescriptionRef formatDescription = nil;
    CMMediaType mediaType = -1;
    CMMediaType subMediaType = -1;
    
    // Se temos um buffer de entrada, extraímos suas informações
    if (originSampleBuffer != nil) {
        formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
        mediaType = CMFormatDescriptionGetMediaType(formatDescription);
        subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
        
        vcam_logf(@"Buffer original - MediaType: %d, SubMediaType: %d", (int)mediaType, (int)subMediaType);
        
        // Se não for vídeo, retornamos o buffer original sem alterações
        if (mediaType != kCMMediaType_Video) {
            vcam_log(@"Não é vídeo, retornando buffer original sem alterações");
            return originSampleBuffer;
        }
    } else {
        vcam_log(@"Nenhum buffer de entrada fornecido");
    }

    // Verificamos se existe um arquivo de vídeo para substituição
    if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) {
        vcam_log(@"Arquivo de vídeo para substituição não encontrado, retornando NULL");
        return nil;
    }
    
    // Se já temos um buffer válido e não precisamos forçar renovação, retornamos o mesmo
    if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) {
        vcam_log(@"Reutilizando buffer existente");
        return sampleBuffer;
    }

    // Controle de tempo para renovação do vídeo
    static NSTimeInterval renewTime = 0;
    
    // Verifica se há um novo arquivo de vídeo para substituição
    if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - renewTime > 3) {
            renewTime = nowTime;
            g_bufferReload = YES;
            vcam_log(@"Arquivo de vídeo atualizado, forçando recarga");
        }
    }

    // Se precisamos recarregar o vídeo, inicializamos os componentes de leitura
    if (g_bufferReload) {
        g_bufferReload = NO;
        vcam_log(@"Iniciando carregamento do novo vídeo");
        
        @try{
            // Criamos um AVAsset a partir do arquivo de vídeo
            AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
            vcam_logf(@"Carregando vídeo do caminho: %@", g_tempFile);
            
            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject]; // Obtém a trilha de vídeo
            vcam_logf(@"Informações da trilha de vídeo: %@", videoTrack);
            
            // Configuramos outputs para diferentes formatos de pixel
            // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: YUV420 para vídeo SD
            // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: YUV422 para vídeo HD
            // kCVPixelFormatType_32BGRA: Formato BGRA para OpenGL e CoreImage
            
            videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
            videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
            
            [reader addOutput:videoTrackout_32BGRA];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarVideoRange];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarFullRange];

            [reader startReading];
            vcam_log(@"Leitura do vídeo iniciada com sucesso");
            
        }@catch(NSException *except) {
            vcam_logf(@"ERRO ao inicializar leitura do vídeo: %@", except);
        }
    }

    // Obtém um novo frame de cada formato
    vcam_log(@"Copiando próximo frame de cada formato");
    CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];

    CMSampleBufferRef newsampleBuffer = nil;
    
    // Escolhe o buffer adequado com base no formato do buffer original
    switch(subMediaType) {
        case kCVPixelFormatType_32BGRA:
            vcam_log(@"Usando formato: kCVPixelFormatType_32BGRA");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            vcam_log(@"Usando formato: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            vcam_log(@"Usando formato: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange");
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer);
            break;
        default:
            vcam_logf(@"Formato não reconhecido (%d), usando 32BGRA como padrão", (int)subMediaType);
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
    }
    
    // Libera os buffers temporários
    if (videoTrackout_32BGRA_Buffer != nil) {
        CFRelease(videoTrackout_32BGRA_Buffer);
        vcam_log(@"Buffer 32BGRA liberado");
    }
    if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer != nil) {
        CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
        vcam_log(@"Buffer 420YpCbCr8BiPlanarVideoRange liberado");
    }
    if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer != nil) {
        CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);
        vcam_log(@"Buffer 420YpCbCr8BiPlanarFullRange liberado");
    }

    // Se não conseguimos criar um novo buffer, marca para recarregar na próxima vez
    if (newsampleBuffer == nil) {
        g_bufferReload = YES;
        vcam_log(@"Falha ao criar novo sample buffer, marcando para recarregar");
    } else {
        // Libera o buffer antigo se existir
        if (sampleBuffer != nil) {
            CFRelease(sampleBuffer);
            vcam_log(@"Buffer antigo liberado");
        }
        
        // Se temos um buffer original, precisamos copiar propriedades dele
        if (originSampleBuffer != nil) {
            vcam_log(@"Processando buffer com base no original");
            
            CMSampleBufferRef copyBuffer = nil;
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);
            
            if (pixelBuffer) {
                vcam_logf(@"Dimensões do pixel buffer: %ldx%ld",
                          CVPixelBufferGetWidth(pixelBuffer),
                          CVPixelBufferGetHeight(pixelBuffer));
            }

            // Obtém informações de tempo do buffer original
            CMSampleTimingInfo sampleTime = {
                .duration = CMSampleBufferGetDuration(originSampleBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
            };
            
            vcam_logf(@"Timing do buffer - Duration: %lld, PTS: %lld, DTS: %lld",
                     sampleTime.duration.value,
                     sampleTime.presentationTimeStamp.value,
                     sampleTime.decodeTimeStamp.value);

            // Cria descrição de formato de vídeo para o novo buffer
            CMVideoFormatDescriptionRef videoInfo = nil;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
            
            // Cria um novo buffer baseado no pixelBuffer mas com as informações de tempo do original
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
            
            if (copyBuffer != nil) {
                vcam_log(@"Buffer copiado com sucesso");
                
                // Copia metadados EXIF e TIFF do buffer original
                CFDictionaryRef exifAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                CFDictionaryRef TIFFAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);

                // Define metadados EXIF
                if (exifAttachments != nil) {
                    CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exifAttachments, kCMAttachmentMode_ShouldPropagate);
                    vcam_log(@"Metadados EXIF copiados");
                }
                
                // Define metadados TIFF
                if (TIFFAttachments != nil) {
                    CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", TIFFAttachments, kCMAttachmentMode_ShouldPropagate);
                    vcam_log(@"Metadados TIFF copiados");
                }
                
                sampleBuffer = copyBuffer;
            } else {
                vcam_log(@"FALHA ao criar buffer copiado");
            }
            
            CFRelease(newsampleBuffer);
        } else {
            // Se não temos buffer original, usamos o novo diretamente
            vcam_log(@"Usando novo buffer diretamente (sem buffer original)");
            sampleBuffer = newsampleBuffer;
        }
    }
    
    // Verifica se o buffer final é válido
    if (CMSampleBufferIsValid(sampleBuffer)) {
        vcam_log(@"GetFrame::getCurrentFrame - Retornando buffer válido");
        return sampleBuffer;
    }
    
    vcam_log(@"GetFrame::getCurrentFrame - Retornando NULL (buffer inválido)");
    return nil;
}

// Método para obter a janela principal da aplicação
+(UIWindow*)getKeyWindow{
    vcam_log(@"GetFrame::getKeyWindow - Buscando janela principal");
    
    // Necessário usar [GetFrame getKeyWindow].rootViewController
    UIWindow *keyWindow = nil;
    if (keyWindow == nil) {
        NSArray *windows = UIApplication.sharedApplication.windows;
        for(UIWindow *window in windows){
            if(window.isKeyWindow) {
                keyWindow = window;
                vcam_log(@"Janela principal encontrada");
                break;
            }
        }
    }
    return keyWindow;
}
@end


// Elementos de UI para o tweak
CALayer *g_maskLayer = nil;

// Hook na layer de preview da câmera
%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    vcam_logf(@"AVCaptureVideoPreviewLayer::addSublayer - Adicionando sublayer: %@", layer);
    %orig;

    // Configura display link para atualização contínua
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        vcam_log(@"DisplayLink criado para atualização contínua");
    }

    // Adiciona camada de preview se ainda não existe
    if (![[self sublayers] containsObject:g_previewLayer]) {
        vcam_log(@"Configurando camadas de preview");
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];

        // Máscara preta para cobrir a visualização original
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];

        // Inicializa tamanho das camadas na thread principal
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            vcam_logf(@"Tamanho das camadas inicializado: %@",
                     NSStringFromCGRect([UIApplication sharedApplication].keyWindow.bounds));
        });
    }
}

// Método adicionado para atualização contínua do preview
%new
-(void)step:(CADisplayLink *)sender{
    // Controla a visibilidade das camadas baseado na existência do arquivo de vídeo
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        if (g_maskLayer != nil) g_maskLayer.opacity = 1;
        if (g_previewLayer != nil) {
            g_previewLayer.opacity = 1;
            [g_previewLayer setVideoGravity:[self videoGravity]];
        }
    } else {
        if (g_maskLayer != nil) g_maskLayer.opacity = 0;
        if (g_previewLayer != nil) g_previewLayer.opacity = 0;
    }

    // Se a câmera está ativa e a camada de preview existe
    if (g_cameraRunning && g_previewLayer != nil) {
        vcam_logf(@"step: Atualizando preview, camera running: %@, readyForMoreMediaData: %@",
                 g_cameraRunning ? @"Sim" : @"Não",
                 g_previewLayer.readyForMoreMediaData ? @"Sim" : @"Não");
        
        // Atualiza o tamanho da camada de preview
        g_previewLayer.frame = self.bounds;
        
        // Aplica rotação com base na orientação
        switch(g_photoOrientation) {
            case AVCaptureVideoOrientationPortrait:
                vcam_log(@"Orientação: Portrait");
            case AVCaptureVideoOrientationPortraitUpsideDown:
                vcam_log(@"Orientação: PortraitUpsideDown");
                g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                break;
            case AVCaptureVideoOrientationLandscapeRight:
                vcam_log(@"Orientação: LandscapeRight");
                g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                break;
            case AVCaptureVideoOrientationLandscapeLeft:
                vcam_log(@"Orientação: LandscapeLeft");
                g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0);
                break;
            default:
                vcam_log(@"Orientação: Usando transformação padrão");
                g_previewLayer.transform = self.transform;
        }

        // Controle para evitar conflito com VideoDataOutput
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        
        // Atualiza o preview apenas se não houver atualização recente do VideoDataOutput
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            // Controle de taxa de frames (33 FPS)
            if (nowTime - refreshTime > 1000 / 33 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                g_photoOrientation = -1;
                vcam_logf(@"Atualizando frame, timestamp: %f", nowTime);
                
                // Obtém o próximo frame
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
                if (newBuffer != nil) {
                    vcam_log(@"Novo buffer obtido para preview");
                    
                    // Limpa quaisquer frames na fila
                    [g_previewLayer flush];
                    
                    // Cria uma cópia e adiciona à camada de preview
                    static CMSampleBufferRef copyBuffer = nil;
                    if (copyBuffer != nil) CFRelease(copyBuffer);
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer != nil) {
                        [g_previewLayer enqueueSampleBuffer:copyBuffer];
                        vcam_log(@"Buffer enfileirado para exibição");
                    }

                    // Informações da câmera para debugging
                    NSDate *datenow = [NSDate date];
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                    CGSize dimensions = self.bounds.size;
                    NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%.0f  H:%.0f",
                        [formatter stringFromDate:datenow],
                        [NSProcessInfo processInfo].processName,
                        [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, @"preview"],
                        dimensions.width, dimensions.height
                    ];
                    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                    [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
                    vcam_logf(@"Informações da câmera atualizadas: %@", str);
                }
            }
        }
    }
}
%end


// Hook para gerenciar o estado da sessão da câmera
%hook AVCaptureSession
// Método chamado quando a câmera é iniciada
-(void) startRunning {
    vcam_log(@"AVCaptureSession::startRunning - Câmera iniciando");
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_refreshPreviewByVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000;
    vcam_logf(@"AVCaptureSession iniciada com preset: %@", [self sessionPreset]);
    %orig;
}

// Método chamado quando a câmera é parada
-(void) stopRunning {
    vcam_log(@"AVCaptureSession::stopRunning - Câmera parando");
    g_cameraRunning = NO;
    %orig;
}

// Método chamado quando um dispositivo de entrada é adicionado à sessão
- (void)addInput:(AVCaptureDeviceInput *)input {
    vcam_logf(@"AVCaptureSession::addInput - Adicionando dispositivo: %@", [input device]);
    
    // Determina qual câmera está sendo usada (frontal ou traseira)
    if ([[input device] position] > 0) {
        g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F";
        vcam_logf(@"Posição da câmera definida como: %@", g_cameraPosition);
    }
    %orig;
}

// Método chamado quando um dispositivo de saída é adicionado à sessão
- (void)addOutput:(AVCaptureOutput *)output{
    vcam_logf(@"AVCaptureSession::addOutput - Adicionando output: %@", output);
    %orig;
}
%end


// Hook para captura de imagens estáticas
%hook AVCaptureStillImageOutput
// Método chamado quando uma foto é tirada
- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler{
    vcam_logf(@"AVCaptureStillImageOutput::captureStillImageAsynchronously - Tirando foto, connection: %@", connection);
    g_canReleaseBuffer = NO;
    
    // Cria um novo handler para interceptar o retorno
    void (^newHandler)(CMSampleBufferRef imageDataSampleBuffer, NSError *error) = ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        vcam_log(@"Handler de captura de foto chamado");
        
        // Obtém o frame atual para substituir a foto
        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:imageDataSampleBuffer :YES];
        if (newBuffer != nil) {
            vcam_log(@"Substituindo buffer da foto por vídeo");
            imageDataSampleBuffer = newBuffer;
        } else {
            vcam_log(@"Mantendo buffer original da foto (não foi possível substituir)");
        }
        
        // Chama o handler original com o buffer modificado
        handler(imageDataSampleBuffer, error);
        g_canReleaseBuffer = YES;
    };
    
    // Chama o método original com o handler modificado
    %orig(connection, [newHandler copy]);
}

// Método para converter um buffer JPEG em NSData (usado para salvar foto)
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer{
    vcam_log(@"AVCaptureStillImageOutput::jpegStillImageNSDataRepresentation - Convertendo buffer para JPEG");
    
    // Tenta obter um frame do vídeo para substituir
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        vcam_log(@"Usando vídeo personalizado para JPEG");
        
        // Obtém o buffer de pixels do vídeo
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);

        // Cria uma imagem CIImage a partir do buffer
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        
        // Aplica rotação conforme orientação
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait:
                    vcam_log(@"Orientação JPEG: Portrait");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];
                    break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    vcam_log(@"Orientação JPEG: PortraitUpsideDown");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    vcam_log(@"Orientação JPEG: LandscapeRight");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    vcam_log(@"Orientação JPEG: LandscapeLeft");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                    break;
            }
        }
        
        // Cria UIImage a partir do CIImage
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        
        // Aplica espelhamento se necessário
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            vcam_log(@"Aplicando espelhamento à imagem");
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        
        // Converte para dados JPEG
        NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
        vcam_logf(@"JPEG gerado com tamanho: %lu bytes", (unsigned long)[theNewPhoto length]);
        return theNewPhoto;
    }
    
    // Se não conseguimos substituir, retorna o JPEG original
    vcam_log(@"Retornando JPEG original (não foi possível substituir)");
    return %orig;
}
%end

// Hook para a nova API de captura de foto (iOS 10+)
%hook AVCapturePhotoOutput
// Método para converter buffer JPEG em NSData
+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer{
    vcam_log(@"AVCapturePhotoOutput::JPEGPhotoDataRepresentation - Processando");
    
    // Tenta obter um frame do vídeo para substituir
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        vcam_log(@"Usando vídeo personalizado para foto JPEG");
        
        // Obtém o buffer de pixels do vídeo
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        
        // Aplica rotação conforme orientação
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait:
                    vcam_log(@"Orientação: Portrait");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp];
                    break;
                case AVCaptureVideoOrientationPortraitUpsideDown:
                    vcam_log(@"Orientação: PortraitUpsideDown");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown];
                    break;
                case AVCaptureVideoOrientationLandscapeRight:
                    vcam_log(@"Orientação: LandscapeRight");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight];
                    break;
                case AVCaptureVideoOrientationLandscapeLeft:
                    vcam_log(@"Orientação: LandscapeLeft");
                    ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                    break;
            }
        }
        
        // Cria UIImage a partir do CIImage
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        
        // Aplica espelhamento se necessário
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
            vcam_log(@"Aplicando espelhamento à imagem");
            uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        }
        
        // Converte para dados JPEG
        NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
        vcam_logf(@"JPEG gerado com tamanho: %lu bytes", (unsigned long)[theNewPhoto length]);
        return theNewPhoto;
    }
    
    // Se não conseguimos substituir, retorna o JPEG original
    vcam_log(@"Retornando JPEG original (não foi possível substituir)");
    return %orig;
}

// Método para capturar foto com API moderna (iOS 10+)
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate{
    vcam_logf(@"AVCapturePhotoOutput::capturePhotoWithSettings - Iniciando captura com settings: %@, delegate: %@", settings, delegate);
    
    // Verificações de segurança
    if (settings == nil || delegate == nil) {
        vcam_log(@"Settings ou delegate nulos, retornando sem ação");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([delegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if ([hooked containsObject:className] == NO) {
        vcam_logf(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];

        // Para iOS 10.0 e posteriores (método antigo)
        if (@available(iOS 10.0, *)) {
            vcam_log(@"Hooking método iOS 10: captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
            
            __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *output, CMSampleBufferRef photoSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *output, CMSampleBufferRef photoSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error){
                    vcam_log(@"Método captureOutput:didFinishProcessingPhotoSampleBuffer chamado");
                    g_canReleaseBuffer = NO;
                    
                    // Obtém um frame do vídeo para substituir o buffer da foto
                    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:photoSampleBuffer :NO];
                    if (newBuffer != nil) {
                        vcam_log(@"Substituindo buffer da foto por vídeo");
                        photoSampleBuffer = newBuffer;
                    } else {
                        vcam_log(@"Mantendo buffer original (não foi possível substituir)");
                    }
                    
                    // Chama o método original com o buffer possivelmente substituído
                    @try{
                        original_method(self, @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:), output, photoSampleBuffer, previewPhotoSampleBuffer, resolvedSettings, bracketSettings, error);
                        g_canReleaseBuffer = YES;
                    }@catch(NSException *except) {
                        vcam_logf(@"ERRO ao chamar método original: %@", except);
                    }
                }), (IMP*)&original_method
            );
            
            // Hook para processamento de RAW (menos comum)
            vcam_log(@"Hooking método iOS 10 para RAW: captureOutput:didFinishProcessingRawPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
            __block void (*original_method2)(id self, SEL _cmd, AVCapturePhotoOutput *output, CMSampleBufferRef rawSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingRawPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *output, CMSampleBufferRef rawSampleBuffer, CMSampleBufferRef previewPhotoSampleBuffer, AVCaptureResolvedPhotoSettings *resolvedSettings, AVCaptureBracketedStillImageSettings *bracketSettings, NSError *error){
                    vcam_log(@"Método captureOutput:didFinishProcessingRawPhotoSampleBuffer chamado");
                    return original_method2(self, @selector(captureOutput:didFinishProcessingRawPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:), output, rawSampleBuffer, previewPhotoSampleBuffer, resolvedSettings, bracketSettings, error);
                }), (IMP*)&original_method2
            );
        }

        // Para iOS 11.0 e posteriores (método mais novo)
        if (@available(iOS 11.0, *)){
            vcam_log(@"Hooking método iOS 11+: captureOutput:didFinishProcessingPhoto:error:");
            
            __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) = nil;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:),
                imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error){
                    vcam_log(@"Método captureOutput:didFinishProcessingPhoto:error: chamado");
                    
                    // Se não temos arquivo de vídeo, chamamos direto o método original
                    if (![g_fileManager fileExistsAtPath:g_tempFile]) {
                        vcam_log(@"Sem vídeo para substituição, usando foto original");
                        return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                    }

                    // Bloqueamos liberação de buffer durante o processamento
                    g_canReleaseBuffer = NO;
                    static CMSampleBufferRef copyBuffer = nil;

                    // Criamos temporariamente um buffer a partir da foto
                    vcam_log(@"Criando buffer temporário a partir da foto");
                    CMSampleBufferRef tempBuffer = nil;
                    CVPixelBufferRef tempPixelBuffer = photo.pixelBuffer;
                    CMSampleTimingInfo sampleTime = {0,};
                    CMVideoFormatDescriptionRef videoInfo = nil;
                    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, &videoInfo);
                    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &tempBuffer);

                    // Obtemos novos dados do vídeo
                    vcam_logf(@"Obtendo frame do vídeo para substituir foto. tempBuffer: %p, pixelBuffer: %p", tempBuffer, photo.pixelBuffer);
                    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:tempBuffer :YES];
                    if (tempBuffer != nil) {
                        CFRelease(tempBuffer); // Liberamos o buffer temporário
                        vcam_log(@"Buffer temporário liberado");
                    }

                    // Se temos um novo buffer do vídeo, alteramos os métodos do objeto photo
                    if (newBuffer != nil) {
                        vcam_log(@"Substituindo métodos do objeto photo para usar vídeo");
                        
                        if (copyBuffer != nil) CFRelease(copyBuffer);
                        CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);

                        __block CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(copyBuffer);
                        CIImage *ciimage = [CIImage imageWithCVImageBuffer:imageBuffer];

                        // Rotacionamos para orientação correta
                        CIImage *ciimageRotate = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                        CIContext *cicontext = [CIContext new];
                        __block CGImageRef _Nullable cgimage = [cicontext createCGImage:ciimageRotate fromRect:ciimageRotate.extent];

                        UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                        __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
                        vcam_logf(@"JPEG criado com tamanho: %lu bytes", (unsigned long)[theNewPhoto length]);

                        // Hooking método para obter representação do arquivo
                        vcam_log(@"Hooking método fileDataRepresentationWithCustomizer:");
                        __block NSData *(*fileDataRepresentationWithCustomizer)(id self, SEL _cmd, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer);
                        MSHookMessageEx(
                            [photo class], @selector(fileDataRepresentationWithCustomizer:),
                            imp_implementationWithBlock(^(id self, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer){
                                vcam_log(@"Método fileDataRepresentationWithCustomizer: chamado");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                                    vcam_log(@"Retornando dados JPEG personalizados");
                                    return theNewPhoto;
                                }
                                vcam_log(@"Chamando implementação original");
                                return fileDataRepresentationWithCustomizer(self, @selector(fileDataRepresentationWithCustomizer:), customizer);
                            }), (IMP*)&fileDataRepresentationWithCustomizer
                        );

                        // Hooking método para obter representação de dados direta
                        vcam_log(@"Hooking método fileDataRepresentation");
                        __block NSData *(*fileDataRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(fileDataRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                vcam_log(@"Método fileDataRepresentation chamado");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                                    vcam_log(@"Retornando dados JPEG personalizados");
                                    return theNewPhoto;
                                }
                                vcam_log(@"Chamando implementação original");
                                return fileDataRepresentation(self, @selector(fileDataRepresentation));
                            }), (IMP*)&fileDataRepresentation
                        );

                        // Hooking método para obter buffer de pixels de preview
                        vcam_log(@"Hooking método previewPixelBuffer");
                        __block CVPixelBufferRef *(*previewPixelBuffer)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(previewPixelBuffer),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                vcam_log(@"Método previewPixelBuffer chamado");
                                return nil; // Retornamos nil para evitar problemas de rotação
                            }), (IMP*)&previewPixelBuffer
                        );

                        // Hooking método para obter buffer de pixels
                        vcam_log(@"Hooking método pixelBuffer");
                        __block CVImageBufferRef (*pixelBuffer)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(pixelBuffer),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                vcam_log(@"Método pixelBuffer chamado");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                                    vcam_log(@"Retornando buffer de imagem personalizado");
                                    return imageBuffer;
                                }
                                vcam_log(@"Chamando implementação original");
                                return pixelBuffer(self, @selector(pixelBuffer));
                            }), (IMP*)&pixelBuffer
                        );

                        // Hooking método para obter representação CGImage
                        vcam_log(@"Hooking método CGImageRepresentation");
                        __block CGImageRef _Nullable(*CGImageRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(CGImageRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                vcam_log(@"Método CGImageRepresentation chamado");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                                    vcam_log(@"Retornando CGImage personalizado");
                                    return cgimage;
                                }
                                vcam_log(@"Chamando implementação original");
                                return CGImageRepresentation(self, @selector(CGImageRepresentation));
                            }), (IMP*)&CGImageRepresentation
                        );

                        // Hooking método para obter representação CGImage de preview
                        vcam_log(@"Hooking método previewCGImageRepresentation");
                        __block CGImageRef _Nullable(*previewCGImageRepresentation)(id self, SEL _cmd);
                        MSHookMessageEx(
                            [photo class], @selector(previewCGImageRepresentation),
                            imp_implementationWithBlock(^(id self, SEL _cmd){
                                vcam_log(@"Método previewCGImageRepresentation chamado");
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                                    vcam_log(@"Retornando CGImage personalizado");
                                    return cgimage;
                                }
                                vcam_log(@"Chamando implementação original");
                                return previewCGImageRepresentation(self, @selector(previewCGImageRepresentation));
                            }), (IMP*)&previewCGImageRepresentation
                        );
                    }
                    g_canReleaseBuffer = YES;
                    
                    // Chamamos o método original para finalizar o processamento
                    vcam_log(@"Chamando método original captureOutput:didFinishProcessingPhoto:error:");
                    return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                }), (IMP*)&original_method
            );
        }
    }
    
    vcam_logf(@"Chamando método original capturePhotoWithSettings:delegate: settings: %@, delegate: %@", settings, delegate);
    %orig;
}
%end

// Hook para intercepção do fluxo de vídeo em tempo real
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    vcam_logf(@"AVCaptureVideoDataOutput::setSampleBufferDelegate - Delegate: %@, Queue: %@", sampleBufferDelegate, sampleBufferCallbackQueue);
    
    // Verificações de segurança
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        vcam_log(@"Delegate ou queue nulos, chamando método original sem modificações");
        return %orig;
    }
    
    // Lista para controlar quais classes já foram "hooked"
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    
    // Obtém o nome da classe do delegate
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    
    // Verifica se esta classe já foi "hooked"
    if ([hooked containsObject:className] == NO) {
        vcam_logf(@"Hooking nova classe de delegate: %@", className);
        [hooked addObject:className];
        
        // Hook para o método que recebe cada frame de vídeo
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;

        // Verifica as configurações de vídeo
        vcam_logf(@"Configurações de vídeo: %@", [self videoSettings]);
        
        // Hook do método de recebimento de frames
        MSHookMessageEx(
            [sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
                // Atualiza timestamp para controle de conflito com preview
                g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
                vcam_logf(@"Método didOutputSampleBuffer chamado, timestamp: %f", g_refreshPreviewByVideoDataOutputTime);

                // Obtém um frame do vídeo para substituir o buffer
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];

                // Atualiza o preview usando o buffer
                NSString *previewType = @"buffer";
                g_photoOrientation = [connection videoOrientation];
                vcam_logf(@"Orientação do vídeo: %d", (int)g_photoOrientation);
                
                if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                    vcam_log(@"Atualizando preview usando buffer");
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
                    previewType = @"buffer - preview";
                }

                // Atualiza informações de depuração periodicamente
                static NSTimeInterval oldTime = 0;
                NSTimeInterval nowTime = g_refreshPreviewByVideoDataOutputTime;
                if (nowTime - oldTime > 3000) { // A cada 3 segundos
                    oldTime = nowTime;
                    vcam_log(@"Atualizando informações de depuração");
                    
                    // Obtém dimensões do buffer
                    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
                    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                    
                    // Formata data e hora
                    NSDate *datenow = [NSDate date];
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                    
                    // Cria string com informações
                    NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%d  H:%d",
                        [formatter stringFromDate:datenow],
                        [NSProcessInfo processInfo].processName,
                        [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, previewType],
                        dimensions.width, dimensions.height
                    ];
                    
                    // Salva na área de transferência com prefixo especial
                    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                    [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
                    vcam_logf(@"Informações atualizadas: %@", str);
                }
                
                // Chama o método original com o buffer possivelmente substituído
                vcam_log(@"Chamando método original didOutputSampleBuffer");
                return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer != nil? newBuffer: sampleBuffer, connection);
            }), (IMP*)&original_method
        );
    }
    
    // Chama o método original
    %orig;
}
%end

// Interface para seleção de imagens da galeria
@interface CCUIImagePickerDelegate : NSObject <UINavigationControllerDelegate,UIImagePickerControllerDelegate>
@end

@implementation CCUIImagePickerDelegate
// Método chamado quando uma imagem/vídeo é selecionado
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    vcam_log(@"CCUIImagePickerDelegate::didFinishPickingMediaWithInfo - Seleção concluída");
    vcam_logf(@"Informações da mídia selecionada: %@", info);
    
    // Fecha o seletor de imagens
    [[GetFrame getKeyWindow].rootViewController dismissViewControllerAnimated:YES completion:nil];
    
    // Obtém o caminho do arquivo selecionado
    NSString *selectFile = info[@"UIImagePickerControllerMediaURL"];
    vcam_logf(@"Arquivo selecionado: %@", selectFile);
    
    // Remove arquivo temporário anterior se existir
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        vcam_log(@"Removendo arquivo temporário anterior");
        [g_fileManager removeItemAtPath:g_tempFile error:nil];
    }

    // Copia o arquivo selecionado para o local temporário
    if ([g_fileManager copyItemAtPath:selectFile toPath:g_tempFile error:nil]) {
        vcam_log(@"Arquivo copiado com sucesso");
        
        // Cria uma marca temporária para indicar que o arquivo foi atualizado
        [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
        sleep(1);
        [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
        vcam_log(@"Marca de atualização criada e removida");
    } else {
        vcam_log(@"FALHA ao copiar arquivo");
    }
}

// Método chamado quando a seleção é cancelada
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    vcam_log(@"CCUIImagePickerDelegate::imagePickerControllerDidCancel - Seleção cancelada");
    [[GetFrame getKeyWindow].rootViewController dismissViewControllerAnimated:YES completion:nil];
}
@end


// Variáveis para controle da interface de usuário
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;
static NSString *g_downloadAddress = @""; // Endereço de download
static BOOL g_downloadRunning = NO; // Flag indicando download em andamento

// Função para abrir seletor de vídeo da galeria
void ui_selectVideo(){
    vcam_log(@"ui_selectVideo - Abrindo seletor de vídeo");
    
    // Cria e configura o delegate se necessário
    static CCUIImagePickerDelegate *delegate = nil;
    if (delegate == nil) delegate = [CCUIImagePickerDelegate new];
    
    // Configura o seletor de imagens
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = [NSArray arrayWithObjects:@"public.movie",/* @"public.image",*/ nil];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    if (@available(iOS 11.0, *)) picker.videoExportPreset = AVAssetExportPresetPassthrough;
    picker.allowsEditing = YES;
    picker.delegate = delegate;
    
    // Apresenta o seletor
    [[GetFrame getKeyWindow].rootViewController presentViewController:picker animated:YES completion:nil];
    vcam_log(@"Seletor de vídeo apresentado");
}

// Interface para controle de volume do sistema
@interface AVSystemController : NSObject
+ (id)sharedAVSystemController;
- (BOOL)getVolume:(float*)arg1 forCategory:(id)arg2;
- (BOOL)setVolumeTo:(float)arg1 forCategory:(id)arg2;
@end

/**
 * Função para download de vídeo de URL remota
 * @param bool quick Se verdadeiro, tenta reduzir notificações visuais
 */
void ui_downloadVideo(){
    vcam_log(@"ui_downloadVideo - Iniciando processo de download");
    
    // Verifica se já existe um download em andamento
    if (g_downloadRunning) {
        vcam_log(@"Download já em andamento, retornando");
        return;
    }

    // Bloco para execução do download
    void (^startDownload)(void) = ^{
        vcam_log(@"Iniciando download de vídeo");
        g_downloadRunning = YES;
        
        // Define caminho para o arquivo temporário de download
        NSString *tempPath = [NSString stringWithFormat:@"%@.downloading.mov", g_tempFile];
        vcam_logf(@"URL de download: %@", g_downloadAddress);
        vcam_logf(@"Caminho temporário: %@", tempPath);

        // Baixa os dados do URL
        NSData *urlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:g_downloadAddress]];
        if (urlData) {
            vcam_logf(@"Download concluído, tamanho: %lu bytes", (unsigned long)[urlData length]);
            
            // Salva os dados baixados no arquivo temporário
            if ([urlData writeToFile:tempPath atomically:YES]) {
                vcam_log(@"Arquivo salvo, verificando se é um vídeo válido");
                
                // Verifica se o arquivo é um vídeo válido
                AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", tempPath]]];
                if (asset.playable) {
                    vcam_log(@"Vídeo válido confirmado");
                    
                    // Remove arquivo anterior se existir
                    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                        vcam_log(@"Removendo arquivo anterior");
                        [g_fileManager removeItemAtPath:g_tempFile error:nil];
                    }
                    
                    // Move o arquivo baixado para o local final
                    [g_fileManager moveItemAtPath:tempPath toPath:g_tempFile error:nil];
                    [[%c(AVSystemController) sharedAVSystemController] setVolumeTo:0 forCategory:@"Ringtone"];
                    
                    // Cria marca temporária para indicar mudança de vídeo
                    vcam_log(@"Criando marca de atualização");
                    [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
                    sleep(1);
                    [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
                    vcam_log(@"Marca de atualização removida");
                } else {
                    vcam_log(@"Arquivo não é um vídeo válido, removendo");
                    if ([g_fileManager fileExistsAtPath:tempPath]) [g_fileManager removeItemAtPath:tempPath error:nil];
                }
            } else {
                vcam_log(@"Falha ao salvar arquivo baixado");
                // Remove arquivo existente caso falhe o download
                if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
            }
        } else {
            vcam_log(@"Falha ao baixar dados da URL");
            if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
        }
        
        // Reseta o volume para confirmar conclusão
        [[%c(AVSystemController) sharedAVSystemController] setVolumeTo:0 forCategory:@"Ringtone"];
        g_downloadRunning = NO;
        vcam_log(@"Processo de download finalizado");
    };
    
    // Executa o download em thread separada
    dispatch_async(dispatch_queue_create("download", nil), startDownload);
}

// Hook para os controles de volume
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    vcam_logf(@"VolumeControl::increaseVolume - timestamp: %f", nowtime);
    
    // Verifica se o botão de diminuir volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_down_time != 0 && nowtime - g_volume_down_time < 1) {
        vcam_log(@"Sequência volume-down + volume-up detectada");
        
        // Se temos um endereço de download, baixa o vídeo
        // Caso contrário, abre o seletor de vídeo
        if ([g_downloadAddress isEqual:@""]) {
            vcam_log(@"Sem URL de download configurada, abrindo seletor de vídeo");
            ui_selectVideo();
        } else {
            vcam_log(@"URL de download configurada, iniciando download");
            ui_downloadVideo();
        }
    }
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    vcam_log(@"VolumeControl::decreaseVolume");
    static CCUIImagePickerDelegate *delegate = nil;
    if (delegate == nil) delegate = [CCUIImagePickerDelegate new];

    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        vcam_log(@"Sequência volume-up + volume-down detectada, abrindo menu");

        // Verifica informações da câmera na área de transferência
        NSString *str = g_pasteboard.string;
        NSString *infoStr = @"Use a câmera para ver informações";
        if (str != nil && [str hasPrefix:@"CCVCAM"]) {
            str = [str substringFromIndex:6]; // Remove o prefixo "CCVCAM"
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:str options:0];
            NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            infoStr = decodedString;
            vcam_logf(@"Informações obtidas da área de transferência: %@", decodedString);
        }
        
        // Cria alerta para mostrar status e opções
        NSString *title = @"iOS-VCAM";
        if ([g_fileManager fileExistsAtPath:g_tempFile]) {
            title = @"iOS-VCAM ✅";
            vcam_log(@"Vídeo de substituição ativo");
        } else {
            vcam_log(@"Sem vídeo de substituição ativo");
        }
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:infoStr preferredStyle:UIAlertControllerStyleAlert];
        vcam_log(@"Criando menu de opções");

        // Opção para selecionar vídeo da galeria
        UIAlertAction *next = [UIAlertAction actionWithTitle:@"Selecionar vídeo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Selecionar vídeo' escolhida");
            ui_selectVideo();
        }];
        
        // Opção para configurar download de vídeo
        UIAlertAction *download = [UIAlertAction actionWithTitle:@"Baixar vídeo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Baixar vídeo' escolhida");
            
            // Cria alerta para inserir URL de download
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Baixar vídeo" message:@"Use preferencialmente formato MOV\nMP4 também é suportado, outros formatos não foram testados" preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                if ([g_downloadAddress isEqual:@""]) {
                    textField.placeholder = @"URL do vídeo";
                } else {
                    textField.text = g_downloadAddress;
                }
                textField.keyboardType = UIKeyboardTypeURL;
            }];
            
            // Botão de confirmação
            UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"Confirmar" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                g_downloadAddress = alert.textFields[0].text;
                vcam_logf(@"URL de download definida: %@", g_downloadAddress);
                
                // Feedback para o usuário
                NSString *resultStr = @"Modo rápido configurado para download remoto\n\nCertifique-se que a URL é válida\n\nAo concluir, o volume será silenciado\nSe o download falhar, a substituição será desativada";
                if ([g_downloadAddress isEqual:@""]) {
                    resultStr = @"Modo rápido configurado para seleção da galeria";
                }
                UIAlertController* resultAlert = [UIAlertController alertControllerWithTitle:@"Configuração salva" message:resultStr preferredStyle:UIAlertControllerStyleAlert];

                UIAlertAction *ok = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
                [resultAlert addAction:ok];
                [[GetFrame getKeyWindow].rootViewController presentViewController:resultAlert animated:YES completion:nil];
            }];
            
            // Botão de cancelamento
            UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleDefault handler:nil];
            [alert addAction:okAction];
            [alert addAction:cancel];
            [[GetFrame getKeyWindow].rootViewController presentViewController:alert animated:YES completion:nil];
        }];
        
        // Opção para desativar substituição
        UIAlertAction *cancelReplace = [UIAlertAction actionWithTitle:@"Desativar substituição" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Desativar substituição' escolhida");
            if ([g_fileManager fileExistsAtPath:g_tempFile]) {
                vcam_log(@"Removendo arquivo de vídeo");
                [g_fileManager removeItemAtPath:g_tempFile error:nil];
            }
        }];

        // Opção para corrigir espelhamento
        NSString *isMirroredText = @"Corrigir espelhamento";
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) isMirroredText = @"Corrigir espelhamento ✅";
        UIAlertAction *isMirrored = [UIAlertAction actionWithTitle:isMirroredText style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Corrigir espelhamento' escolhida");
            if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) {
                vcam_log(@"Removendo marca de espelhamento");
                [g_fileManager removeItemAtPath:g_isMirroredMark error:nil];
            } else {
                vcam_log(@"Criando marca de espelhamento");
                [g_fileManager createDirectoryAtPath:g_isMirroredMark withIntermediateDirectories:YES attributes:nil error:nil];
            }
        }];
        
        // Opção para cancelar
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil];
        
        // Opção para abrir página de ajuda
        UIAlertAction *showHelp = [UIAlertAction actionWithTitle:@"- Ver ajuda -" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Ver ajuda' escolhida, abrindo página do GitHub");
            NSURL *URL = [NSURL URLWithString:@"https://github.com/trizau/iOS-VCAM"];
            [[UIApplication sharedApplication]openURL:URL];
        }];

        // Adiciona todas as opções ao alerta
        [alertController addAction:next];
        [alertController addAction:download];
        [alertController addAction:cancelReplace];
        [alertController addAction:cancel];
        [alertController addAction:showHelp];
        [alertController addAction:isMirrored];
        
        // Apresenta o alerta
        [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];
    }
    
    // Salva o timestamp atual
    g_volume_down_time = nowtime;
    
    // Chama o método original
    %orig;
}
%end


// Função chamada quando o tweak é carregado
%ctor {
    vcam_log(@"--------------------------------------------------");
    vcam_log(@"VCamTeste - Inicializando tweak");
    
    // Inicializa hooks específicos para versões do iOS
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13, 0, 0}]) {
        vcam_log(@"Detectado iOS 13 ou superior, inicializando hooks para VolumeControl");
        %init(VolumeControl = NSClassFromString(@"SBVolumeControl"));
    }
    
    // Inicializa recursos globais
    vcam_log(@"Inicializando recursos globais");
    g_fileManager = [NSFileManager defaultManager];
    g_pasteboard = [UIPasteboard generalPasteboard];
    
    vcam_logf(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    vcam_logf(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    vcam_log(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor{
    vcam_log(@"VCamTeste - Finalizando tweak");
    
    // Limpa variáveis globais
    g_fileManager = nil;
    g_pasteboard = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    
    vcam_log(@"Tweak finalizado com sucesso");
    vcam_log(@"--------------------------------------------------");
}
