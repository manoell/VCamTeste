#include <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// -------------------- SISTEMA DE LOG --------------------
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
    NSString *logPath = @"/tmp/vcam_debug.log";
    
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
static BOOL g_canReleaseBuffer = YES; // Flag que indica se o buffer pode ser liberado
static BOOL g_bufferReload = YES; // Flag que indica se o vídeo precisa ser recarregado
static AVSampleBufferDisplayLayer *g_previewLayer = nil; // Layer para visualização da câmera
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0; // Timestamp da última atualização por VideoDataOutput
static BOOL g_cameraRunning = NO; // Flag que indica se a câmera está ativa
static NSString *g_cameraPosition = @"B"; // Posição da câmera: "B" (traseira) ou "F" (frontal)
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait; // Orientação do vídeo/foto

// Caminho do arquivo de vídeo padrão
NSString *g_videoFile = @"/tmp/default.mp4";

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
    if ([g_fileManager fileExistsAtPath:g_videoFile] == NO) {
        vcam_log(@"Arquivo de vídeo para substituição não encontrado, retornando NULL");
        return nil;
    }
    
    // Se já temos um buffer válido e não precisamos forçar renovação, retornamos o mesmo
    if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) {
        vcam_log(@"Reutilizando buffer existente");
        return sampleBuffer;
    }

    // Se precisamos recarregar o vídeo, inicializamos os componentes de leitura
    if (g_bufferReload) {
        g_bufferReload = NO;
        vcam_log(@"Iniciando carregamento do novo vídeo");
        
        @try{
            // Criamos um AVAsset a partir do arquivo de vídeo
            AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_videoFile]]];
            vcam_logf(@"Carregando vídeo do caminho: %@", g_videoFile);
            
            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject]; // Obtém a trilha de vídeo
            vcam_logf(@"Informações da trilha de vídeo: %@", videoTrack);
            
            // Configuramos outputs para diferentes formatos de pixel
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
    if ([g_fileManager fileExistsAtPath:g_videoFile]) {
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
                g_photoOrientation = [connection videoOrientation];
                vcam_logf(@"Orientação do vídeo: %d", (int)g_photoOrientation);
                
                if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                    vcam_log(@"Atualizando preview usando buffer");
                    [g_previewLayer flush];
                    [g_previewLayer enqueueSampleBuffer:newBuffer];
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

// Variáveis para controle da interface de usuário
static NSTimeInterval g_volume_up_time = 0;
static NSTimeInterval g_volume_down_time = 0;

// Hook para os controles de volume
%hook VolumeControl
// Método chamado quando volume é aumentado
-(void)increaseVolume {
    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    vcam_logf(@"VolumeControl::increaseVolume - timestamp: %f", nowtime);
    
    // Salva o timestamp atual
    g_volume_up_time = nowtime;
    
    // Chama o método original
    %orig;
}

// Método chamado quando volume é diminuído
-(void)decreaseVolume {
    vcam_log(@"VolumeControl::decreaseVolume");

    NSTimeInterval nowtime = [[NSDate date] timeIntervalSince1970];
    
    // Verifica se o botão de aumentar volume foi pressionado recentemente (menos de 1 segundo)
    if (g_volume_up_time != 0 && nowtime - g_volume_up_time < 1) {
        vcam_log(@"Sequência volume-up + volume-down detectada, abrindo menu");

        // Cria alerta para mostrar status e opções
        NSString *title = @"iOS-VCAM";
        if ([g_fileManager fileExistsAtPath:g_videoFile]) {
            title = @"iOS-VCAM ✅";
            vcam_log(@"Vídeo de substituição ativo");
        } else {
            vcam_log(@"Sem vídeo de substituição ativo");
        }
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:@"Menu de Opções" preferredStyle:UIAlertControllerStyleAlert];
        vcam_log(@"Criando menu de opções");

        // Opção para desativar substituição
        UIAlertAction *cancelReplace = [UIAlertAction actionWithTitle:@"Desativar substituição" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
            vcam_log(@"Opção 'Desativar substituição' escolhida");
            if ([g_fileManager fileExistsAtPath:g_videoFile]) {
                vcam_log(@"Removendo arquivo de vídeo");
                [g_fileManager removeItemAtPath:g_videoFile error:nil];
            }
        }];
        
        // Opção para cancelar
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil];

        // Adiciona todas as opções ao alerta
        [alertController addAction:cancelReplace];
        [alertController addAction:cancel];
        
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
    
    vcam_logf(@"Processo atual: %@", [NSProcessInfo processInfo].processName);
    vcam_logf(@"Bundle ID: %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"]);
    vcam_log(@"Tweak inicializado com sucesso");
}

// Função chamada quando o tweak é descarregado
%dtor{
    vcam_log(@"VCamTeste - Finalizando tweak");
    
    // Limpa variáveis globais
    g_fileManager = nil;
    g_canReleaseBuffer = YES;
    g_bufferReload = YES;
    g_previewLayer = nil;
    g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    
    vcam_log(@"Tweak finalizado com sucesso");
    vcam_log(@"--------------------------------------------------");
}
