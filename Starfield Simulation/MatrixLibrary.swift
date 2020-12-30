//
//  MatrixLibrary.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 30/12/2020.
//

import Foundation

// https://math.stackexchange.com/questions/237369/given-this-transformation-matrix-how-do-i-decompose-it-into-translation-rotati

func extractOrientationMatrix(fullmatrix: float4x4) -> float4x4 {
    let scaling = extractScaling(fullmatrix: fullmatrix)
    
    var matrix_extract_rotation = matrix_identity_float4x4
    matrix_extract_rotation.columns.0.x = 1/scaling.x
    matrix_extract_rotation.columns.1.y = 1/scaling.y
    matrix_extract_rotation.columns.2.z = 1/scaling.z
    
    matrix_extract_rotation = fullmatrix * matrix_extract_rotation
    matrix_extract_rotation.columns.3 = vector_float4(0,0,0,1)
    matrix_extract_rotation.columns.0.w = 0
    matrix_extract_rotation.columns.1.w = 0
    matrix_extract_rotation.columns.2.w = 0
    
    return matrix_extract_rotation
}

func extractTranslationMatrix(fullmatrix: float4x4) -> float4x4 {
    return translationMatrix(translation: fullmatrix.columns.3)
}

func extractScaling(fullmatrix: float4x4) -> vector_float4 {
    
    return vector_float4(simd_length(fullmatrix.columns.0), simd_length(fullmatrix.columns.1), simd_length(fullmatrix.columns.2), 1)
}

func extractTranslation(fullmatrix: float4x4) -> vector_float4 {
    
    let matrix_translation = extractTranslationMatrix(fullmatrix: fullmatrix)
    
    return vector_float4(matrix_translation.columns.3.x, matrix_translation.columns.3.y, matrix_translation.columns.3.z, 1)
}

func translationMatrix(translation : vector_float4) -> float4x4 {
    var _translation = matrix_identity_float4x4
    
    _translation.columns.3.x = translation.x
    _translation.columns.3.y = translation.y
    _translation.columns.3.z = translation.z
    _translation.columns.3.w = translation.w
   
    return _translation
}

func translationMatrix(translation : vector_float3) -> float4x4 {
    return translationMatrix(translation: vector_float4(translation, 1))
}


func mirrorMatrix(x: Bool = false, y: Bool = false, z: Bool = false) -> float4x4 {
    var mirror_matrix = matrix_identity_float4x4
    mirror_matrix.columns.0.x = x ? -1 : 1
    mirror_matrix.columns.1.y = y ? -1 : 1
    mirror_matrix.columns.2.z = z ? -1 : 1
    
    return mirror_matrix
}

func scaleMatrix(scale : Float) -> float4x4 {
    var scale_matrix = (1 / scale) * matrix_identity_float4x4
    
    scale_matrix.columns.3.w = 1
    
    return scale_matrix
}


func rotationMatrix (rotation: vector_float3) -> simd_float4x4 {
    let alpha = rotation.x //https://en.wikipedia.org/wiki/Rotation_matrix
    let beta = rotation.y
    let gamma = rotation.z
    
    return simd_float4x4(simd_float4(cos(alpha)*cos(beta), sin(alpha)*cos(beta), -sin(beta), 0),
                         simd_float4(cos(alpha)*sin(beta)*sin(gamma)-sin(alpha)*cos(gamma), sin(alpha)*sin(beta)*sin(gamma)+cos(alpha)*cos(gamma), cos(beta)*sin(gamma), 0),
                         simd_float4(cos(alpha)*sin(beta)*cos(gamma)+sin(alpha)*sin(gamma), sin(alpha)*sin(beta)*cos(gamma)-cos(alpha)*sin(gamma),
                                     cos(beta)*cos(gamma),0),
                         simd_float4(0, 0, 0, 1))
}

func scaleMatrix (scale: vector_float3) -> simd_float4x4 {
    return simd_float4x4(simd_float4(1/scale.x,0,0,0), // note this is column by column if I understood correctly
                         simd_float4(0,1/scale.y,0,0),
                         simd_float4(0,0,1/scale.z,0),
                         simd_float4(0, 0, 0, 1))
}




