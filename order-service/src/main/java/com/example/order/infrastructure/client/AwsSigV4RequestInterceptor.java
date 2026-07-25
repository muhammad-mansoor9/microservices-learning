package com.example.order.infrastructure.client;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.ClientRequest;
import org.springframework.web.reactive.function.client.ClientResponse;
import org.springframework.web.reactive.function.client.ExchangeFilterFunction;
import org.springframework.web.reactive.function.client.ExchangeFunction;
import reactor.core.publisher.Mono;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.signer.Aws4Signer;
import software.amazon.awssdk.auth.signer.params.Aws4SignerParams;
import software.amazon.awssdk.http.SdkHttpFullRequest;
import software.amazon.awssdk.http.SdkHttpMethod;
import software.amazon.awssdk.regions.Region;

@Component
@Profile("prod")
public class AwsSigV4RequestInterceptor implements ExchangeFilterFunction {

    private static final String SIGNING_SERVICE = "execute-api";

    private final Aws4Signer signer = Aws4Signer.create();
    private final DefaultCredentialsProvider credentialsProvider = DefaultCredentialsProvider.create();

    @Value("${aws.region:us-east-1}")
    private String region;

    @Override
    public Mono<ClientResponse> filter(ClientRequest request, ExchangeFunction next) {
        SdkHttpFullRequest sdkRequest = SdkHttpFullRequest.builder()
                .uri(request.url())
                .method(SdkHttpMethod.fromValue(request.method().name()))
                .build();

        Aws4SignerParams params = Aws4SignerParams.builder()
                .awsCredentials(credentialsProvider.resolveCredentials())
                .signingName(SIGNING_SERVICE)
                .signingRegion(Region.of(region))
                .build();

        SdkHttpFullRequest signed = signer.sign(sdkRequest, params);

        ClientRequest signedRequest = ClientRequest.from(request)
                .headers(h -> signed.headers().forEach(
                        (name, values) -> values.forEach(value -> h.set(name, value))))
                .build();

        return next.exchange(signedRequest);
    }
}
